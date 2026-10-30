import os

# Las pruebas usan SQLite en memoria y no dependen de PostgreSQL ni de la RDS.
for var in ("RDS_HOSTNAME", "RDS_PORT", "RDS_DB_NAME", "RDS_USERNAME", "RDS_PASSWORD"):
    os.environ.pop(var, None)
os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "secreto-solo-para-pruebas-de-al-menos-32-caracteres"

import pytest  # noqa: E402
from flask_jwt_extended import create_access_token  # noqa: E402

from app import create_app, db  # noqa: E402

APP_UUID = "3f2b8c1e-5a4d-4e8b-9c1a-7d6e5f4a3b2c"


@pytest.fixture()
def flask_app():
    app = create_app()
    app.config.update(TESTING=True)
    with app.app_context():
        db.drop_all()
        db.create_all()
    yield app
    with app.app_context():
        db.session.remove()
        db.drop_all()


@pytest.fixture()
def client(flask_app):
    return flask_app.test_client()


@pytest.fixture()
def auth_headers(flask_app):
    with flask_app.app_context():
        token = create_access_token(identity="pruebas")
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def valid_payload():
    return {
        "email": "cliente@ejemplo.com",
        "app_uuid": APP_UUID,
        "blocked_reason": "Solicito no recibir correos",
    }
