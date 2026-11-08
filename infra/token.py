"""Genera el token estatico (Bearer) compatible con Flask-JWT-Extended usando solo la libreria estandar.
Uso en CloudShell:
  JWT_SECRET_KEY=$(aws ssm get-parameter --name /blacklist/JWT_SECRET_KEY --with-decryption --query Parameter.Value --output text) python3 token.py
"""
import base64, hashlib, hmac, json, os, time, uuid


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


now = int(time.time())
header = {"alg": "HS256", "typ": "JWT"}
payload = {"fresh": False, "iat": now, "jti": str(uuid.uuid4()), "type": "access", "sub": "blacklist-client", "nbf": now}
signing_input = f"{b64(json.dumps(header, separators=(',', ':')).encode())}.{b64(json.dumps(payload, separators=(',', ':')).encode())}"
signature = hmac.new(os.environ["JWT_SECRET_KEY"].encode(), signing_input.encode(), hashlib.sha256).digest()
print(f"{signing_input}.{b64(signature)}")
