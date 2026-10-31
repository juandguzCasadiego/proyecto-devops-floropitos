def test_health_responde_ok_sin_token(client):
    response = client.get("/health")

    assert response.status_code == 201
    assert response.get_json() == {"status": "ok"}
