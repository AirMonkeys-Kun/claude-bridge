"""Test if zeb-audio bucket is publicly readable."""
import os
import urllib.request
import urllib.error
from dotenv import load_dotenv
load_dotenv("/home/administrator/projects/chatbot/.env")
import boto3
from botocore.exceptions import ClientError

region = os.getenv("AWS_REGION", "us-east-1")
s3 = boto3.client("s3", region_name=region)

# 1. bucket policy status
print("=== zeb-audio bucket policy status ===")
try:
    r = s3.get_bucket_policy_status(Bucket="zeb-audio")
    print(f"  {r.get('PolicyStatus')}")
except ClientError as e:
    code = e.response.get("Error", {}).get("Code", "?")
    print(f"  FAIL [{code}]: {str(e)[:200]}")

# 2. bucket ACL
print("\n=== zeb-audio bucket ACL ===")
try:
    r = s3.get_bucket_acl(Bucket="zeb-audio")
    print(f"  owner: {r.get('Owner', {}).get('DisplayName', '?')}")
    for grant in r.get("Grants", []):
        print(f"  grant: {grant.get('Permission')} -> {grant.get('Grantee')}")
    if not r.get("Grants"):
        print("  (no grants — private)")
except ClientError as e:
    print(f"  FAIL: {str(e)[:200]}")

# 3. Try anonymous HTTP access (no AWS auth)
print("\n=== Anonymous HTTP access to public URL ===")
url = "https://zeb-audio.s3.eu-west-2.amazonaws.com/introductions/Doctor%20Emma/long/2/e3c3af52.mp3"
req = urllib.request.Request(url, method="HEAD")
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(f"  HTTP {resp.status}")
        print(f"  Content-Length: {resp.headers.get('Content-Length')}")
        print(f"  Content-Type: {resp.headers.get('Content-Type')}")
        print(f"  => PUBLIC READABLE ✅ (S3_PUBLIC_BUCKET=true is correct)")
except urllib.error.HTTPError as e:
    print(f"  HTTP {e.code} {e.reason}")
    if e.code == 403:
        print(f"  => PRIVATE (need S3_PUBLIC_BUCKET=false → presigned URL)")
    else:
        print(f"  => unexpected: {e}")
except Exception as e:
    print(f"  FAIL: {type(e).__name__}: {e}")
