"""Verify S3 bucket accessibility using chatbot's AWS credentials (run inside chatbot .venv)."""
import os, sys
from dotenv import load_dotenv
load_dotenv("/home/administrator/projects/chatbot/.env")
import boto3
from botocore.exceptions import ClientError

region = os.getenv("AWS_REGION", "us-east-1")
print(f"AWS_REGION={region}")
print(f"AWS_ACCESS_KEY_ID={os.getenv('AWS_ACCESS_KEY_ID','')[:12]}...")
print()

s3 = boto3.client("s3", region_name=region)

print("=== ALL buckets this account can see ===")
try:
    r = s3.list_buckets()
    buckets = [b["Name"] for b in r["Buckets"]]
    for b in buckets:
        print(f"  {b}")
    print(f"\nTotal: {len(buckets)} buckets")
except ClientError as e:
    print(f"FAIL list_buckets: {e}")
    sys.exit(1)

print("\n=== Probe candidate audio buckets ===")
candidates = ["zeb-audio", "zebbingo-public-bucket", "zebbingo-audio",
              "zeb-audio-eu-west-2", "zebbingo-stage", "zebbingo-prod"]
for b in candidates:
    in_list = b in buckets
    print(f"\n--- {b} ({'in list' if in_list else 'NOT in list'}) ---")
    try:
        r = s3.list_objects_v2(Bucket=b, MaxKeys=3)
        kc = r.get("KeyCount", 0)
        print(f"  OK KeyCount={kc}")
        for o in r.get("Contents", [])[:3]:
            print(f"    {o['Key']} ({o['Size']}b, {o['LastModified']})")
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "?")
        msg = e.response.get("Error", {}).get("Message", "")[:120]
        print(f"  FAIL [{code}]: {msg}")

print("\n=== Head specific file from error log ===")
target_key = "introductions/Doctor Emma/long/2/e3c3af52.mp3"
for b in ["zeb-audio", "zebbingo-public-bucket"]:
    print(f"\n--- s3://{b}/{target_key} ---")
    try:
        r = s3.head_object(Bucket=b, Key=target_key)
        print(f"  OK: {r.get('ContentLength')} bytes, type={r.get('ContentType')}, modified={r.get('LastModified')}")
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "?")
        msg = e.response.get("Error", {}).get("Message", "")[:120]
        print(f"  FAIL [{code}]: {msg}")

print("\n=== Search 'introductions/' in all accessible buckets ===")
for b in buckets:
    try:
        r = s3.list_objects_v2(Bucket=b, Prefix="introductions/", MaxKeys=3)
        kc = r.get("KeyCount", 0)
        if kc > 0:
            print(f"\n  bucket={b} KeyCount={kc}")
            for o in r.get("Contents", [])[:3]:
                print(f"    {o['Key']} ({o['Size']}b)")
    except ClientError:
        pass
