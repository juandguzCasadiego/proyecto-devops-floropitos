def test_email_en_la_lista_devuelve_is_blocked_true(client, auth_headers, valid_payload):
    client.post("/blacklists", json=valid_payload, headers=auth_headers)

    response = client.get("/blacklists/cliente@ejemplo.com", headers=auth_headers)

    assert response.status_code == 200
    assert response.get_json() == {
        "is_blocked": True,
        "blocked_reason": "Solicito no recibir correos",
    }


def test_email_que_no_esta_devuelve_is_blocked_false(client, auth_headers):
    response = client.get("/blacklists/noexiste@ejemplo.com", headers=auth_headers)

    assert response.status_code == 200
    assert response.get_json() == {"is_blocked": False, "blocked_reason": None}


def test_sin_token_devuelve_401(client):
    response = client.get("/blacklists/cliente@ejemplo.com")

    assert response.status_code == 401


def test_token_invalido_devuelve_401(client):
    headers = {"Authorization": "Bearer token-que-no-es-valido"}

    response = client.get("/blacklists/cliente@ejemplo.com", headers=headers)

    assert response.status_code == 401
