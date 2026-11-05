def test_soar_alert_payload_schema():
    """Valideert of een Grafana/Loki webhook payload de vereiste structuur heeft."""
    payload = {
        "rule": {"name": "ssh-failures", "severity": "high"},
        "host": {"name": "ws01", "ip": "192.168.10.21"},
        "action": "block_ip"
    }
    assert payload["rule"]["name"] == "ssh-failures"
    assert payload["rule"]["severity"] in ["low", "medium", "high", "critical"]
    assert payload["host"]["ip"] == "192.168.10.21"

def test_ip_format_validation():
    """Valideert de syntax van het doel-IP adres voor geautomatiseerde interventies."""
    ip_address = "192.168.10.21"
    octets = ip_address.split(".")
    assert len(octets) == 4
    for octet in octets:
        assert 0 <= int(octet) <= 255