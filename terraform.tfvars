onprem_cidr    = "192.168.10.0/24" # on-prem LAN
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEioC0U2tmX8nxPmXj70NVouo20t4jLrqrsd0KO0Aknw ansible@ansible-node"
# soar_webhook_token, kibana_api_key: pass as TF_VAR_... environment variables, never in this file
kibana_url                  = "" # e.g. https://kibana.example.com (optional, needed for host isolation)
wireguard_client_public_key = "Q3fHQ0quHgo+mWAF0tBEft26Up0zsYOqrq48wcaFtGM="

