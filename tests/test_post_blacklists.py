from app import db
from app.models import BlacklistEntry
from tests.conftest import APP_UUID


def test_agregar_email_devuelve_201_y_lo_guarda(client, flask_app, auth_headers, valid_payload):
    response = client.post("/blacklists", json=valid_payload, headers=auth_headers)

    assert response.status_code == 201
    assert "agregado" in response.get_json()["message"]

    with flask_app.app_context():
        entry = db.session.query(BlacklistEntry).one()
        assert entry.email == "cliente@ejemplo.com"
        assert entry.app_uuid == APP_UUID
        assert entry.blocked_reason == "Solicito no recibir correos"
        assert entry.ip_address == "127.0.0.1"
        assert entry.created_at is not None


def test_el_motivo_es_opcional(client, flask_app, auth_headers):
    payload = {"email": "sinmotivo@ejemplo.com", "app_uuid": APP_UUID}

    response = client.post("/blacklists", json=payload, headers=auth_headers)

    assert response.status_code == 201
    with flask_app.app_context():
        entry = db.session.query(BlacklistEntry).one()
        assert entry.blocked_reason is None


def test_el_email_se_guarda_en_minusculas(client, flask_app, auth_headers):
    payload = {"email": "Cliente@Ejemplo.COM", "app_uuid": APP_UUID}

    response = client.post("/blacklists", json=payload, headers=auth_headers)

    assert response.status_code == 201
    with flask_app.app_context():
        assert db.session.query(BlacklistEntry).one().email == "cliente@ejemplo.com"


def test_guarda_la_ip_original_del_cliente(client, flask_app, auth_headers, valid_payload):
    headers = {**auth_headers, "X-Forwarded-For": "190.1.2.3, 10.0.0.1"}

    response = client.post("/blacklists", json=valid_payload, headers=headers)

    assert response.status_code == 201
    with flask_app.app_context():
        assert db.session.query(BlacklistEntry).one().ip_address == "190.1.2.3"


def test_email_duplicado_devuelve_409(client, auth_headers, valid_payload):
    client.post("/blacklists", json=valid_payload, headers=auth_headers)

    response = client.post("/blacklists", json=valid_payload, headers=auth_headers)

    assert response.status_code == 409
    assert "ya estaba" in response.get_json()["message"]


def test_email_invalido_devuelve_400(client, auth_headers, valid_payload):
    valid_payload["email"] = "nope"

    response = client.post("/blacklists", json=valid_payload, headers=auth_headers)

    assert response.status_code == 400
    assert "email" in response.get_json()["errors"]


def test_sin_app_uuid_devuelve_400(client, auth_headers, valid_payload):
    del valid_payload["app_uuid"]

    response = client.post("/blacklists", json=valid_payload, headers=auth_headers)

    assert response.status_code == 400
    assert "app_uuid" in response.get_json()["errors"]


def test_app_uuid_invalido_devuelve_400(client, auth_headers, valid_payload):
    valid_payload["app_uuid"] = "123"

    response = client.post("/blacklists", json=valid_payload, headers=auth_headers)

    assert response.status_code == 400
    assert "app_uuid" in response.get_json()["errors"]


def test_motivo_de_mas_de_255_caracteres_devuelve_400(client, auth_headers, valid_payload):
    valid_payload["blocked_reason"] = "a" * 256

    response = client.post("/blacklists", json=valid_payload, headers=auth_headers)

    assert response.status_code == 400
    assert "blocked_reason" in response.get_json()["errors"]


def test_cuerpo_que_no_es_json_devuelve_400(client, auth_headers):
    response = client.post("/blacklists", data="hola", headers=auth_headers)

    assert response.status_code == 400


def test_sin_token_devuelve_401(client, valid_payload):
    response = client.post("/blacklists", json=valid_payload)

    assert response.status_code == 401


def test_token_invalido_devuelve_401(client, valid_payload):
    headers = {"Authorization": "Bearer token-que-no-es-valido"}

    response = client.post("/blacklists", json=valid_payload, headers=headers)

    assert response.status_code == 401
