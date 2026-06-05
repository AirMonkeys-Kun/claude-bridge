#!/usr/bin/env python3
"""
vsock_doorbell_daemon - Bridges vsock signals to Unix socket inside sandbox.

Runs OUTSIDE the bwrap sandbox (on VM rootfs).
- Listens on vsock port 9999 for doorbell signals from host
- Creates Unix socket at /tmp/bridge-doorbell.sock accessible inside sandbox
- On vsock connection: rings Unix socket clients (simple doorbell relay)

Protocol:
  vsock side:  Any connection = doorbell ring, connection closed after ACK
  unix side:   Client connects, waits for "DING\n" notification
"""

import socket
import os
import sys
import signal
import select
import time

VSOCK_PORT = 9999
UNIX_SOCK_PATH = "/tmp/bridge-doorbell.sock"
BACKLOG = 5

def create_unix_listener():
    """Create Unix domain socket for sandbox-internal clients"""
    try:
        os.unlink(UNIX_SOCK_PATH)
    except OSError:
        pass
    
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(UNIX_SOCK_PATH)
    os.chmod(UNIX_SOCK_PATH, 0o666)
    s.listen(BACKLOG)
    s.setblocking(False)
    return s

def create_vsock_listener():
    """Create vsock listener for host communication"""
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    s.listen(BACKLOG)
    s.setblocking(False)
    return s

def ring_doorbell(unix_clients):
    """Send doorbell to all connected unix clients"""
    dead = []
    for client in unix_clients:
        try:
            client.send(b'DING\n')
        except (BrokenPipeError, OSError):
            dead.append(client)
    for d in dead:
        unix_clients.remove(d)

def main():
    # Set up Unix socket listener
    try:
        unix_listener = create_unix_listener()
        print(f"[doorbell] Unix socket: {UNIX_SOCK_PATH}")
    except Exception as e:
        print(f"[doorbell] Unix socket setup failed: {e}", file=sys.stderr)
        unix_listener = None
    
    # Set up vsock listener
    try:
        vsock_listener = create_vsock_listener()
        print(f"[doorbell] Vsock listener: port {VSOCK_PORT}")
    except Exception as e:
        print(f"[doorbell] Vsock setup failed: {e}", file=sys.stderr)
        vsock_listener = None
    
    if not unix_listener and not vsock_listener:
        print("[doorbell] No listeners available, exiting", file=sys.stderr)
        sys.exit(1)
    
    unix_clients = []
    
    print("[doorbell] Running. Waiting for connections...")
    
    while True:
        readers = []
        if unix_listener:
            readers.append(unix_listener)
        if vsock_listener:
            readers.append(vsock_listener)
        for c in unix_clients:
            readers.append(c)
        
        try:
            readable, _, _ = select.select(readers, [], [], 1.0)
        except (InterruptedError, KeyboardInterrupt):
            break
        
        for sock in readable:
            if sock is unix_listener:
                client, addr = unix_listener.accept()
                client.setblocking(False)
                unix_clients.append(client)
                print(f"[doorbell] Unix client connected (total: {len(unix_clients)})")
            
            elif sock is vsock_listener:
                client, addr = vsock_listener.accept()
                print(f"[doorbell] Vsock doorbell from host! Ringing {len(unix_clients)} clients")
                ring_doorbell(unix_clients)
                # Send ACK back and close
                try:
                    client.send(b'ACK\n')
                except:
                    pass
                client.close()
            
            else:
                # Data from unix client (unexpected but handle gracefully)
                try:
                    data = sock.recv(1024)
                    if not data:
                        unix_clients.remove(sock)
                        sock.close()
                except:
                    unix_clients.remove(sock)
                    try:
                        sock.close()
                    except:
                        pass
    
    # Cleanup
    for c in unix_clients:
        c.close()
    if unix_listener:
        unix_listener.close()
    if vsock_listener:
        vsock_listener.close()
    try:
        os.unlink(UNIX_SOCK_PATH)
    except:
        pass

if __name__ == '__main__':
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))
    main()
