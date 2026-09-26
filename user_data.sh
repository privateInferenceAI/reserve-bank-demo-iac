#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- Install AWS CLI v2 ---
apt-get update
apt-get install -y curl unzip git jq

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

# --- Install Docker from official Docker repository ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

# --- Install CloudWatch agent from S3 ---
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazon-cloudwatch-agent.deb || apt-get install -f -y

# --- Create project directory and config files ---
mkdir -p /opt/reserve-bank-demo-iac/litellm
mkdir -p /opt/reserve-bank-demo-iac/guardrails
cd /opt/reserve-bank-demo-iac

cat > docker-compose.yml <<'COMPOSEEOF'
services:
  litellm:
    image: ghcr.io/berriai/litellm-database:main-latest
    container_name: gw-litellm
    ports:
      - "0.0.0.0:4000:4000"
    volumes:
      - ./litellm/config.yaml:/app/config.yaml:ro
      - ./guardrails:/app/guardrails:ro
    env_file:
      - .env
    command: --config /app/config.yaml --port 4000
    restart: unless-stopped
COMPOSEEOF

cat > litellm/config.yaml <<'LITELLMEOF'
model_list:
  - model_name: gateway-test
    litellm_params:
      model: openai/gpt-3.5-turbo
      mock_response: "Gateway is responding. This is a mock response for Phase 1 testing."

  - model_name: company-claude
    litellm_params:
      model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
      aws_region_name: us-east-1

litellm_settings:
  drop_params: true
  set_verbose: false
  callbacks: guardrails.callback.proxy_handler_instance

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  salt_key: os.environ/LITELLM_SALT_KEY
LITELLMEOF

cat > guardrails/callback.py <<'GUARDEOF'
"""BankGuardrail — LiteLLM CustomGuardrail enforced at the gateway."""

import re

from fastapi import HTTPException
from litellm.integrations.custom_guardrail import CustomGuardrail

DENIED_KEYWORDS = (
    "salary of", "how much does", "ssn", "social security number",
    "ignore previous instructions", "ignore all previous", "you are now", "system:",
)
REFUSAL_MESSAGE = "Request denied by gateway policy. Contact your administrator."
PII_PATTERNS = (r"\b\d{3}-\d{2}-\d{4}\b",)


class BankGuardrail(CustomGuardrail):
    @staticmethod
    def _last_user_text(data: dict) -> str:
        for m in reversed(data.get("messages", []) or []):
            if m.get("role") == "user":
                return (m.get("content") or "").lower()
        return ""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        text = self._last_user_text(data)
        key_alias = getattr(user_api_key_dict, "key_alias", None)
        for kw in DENIED_KEYWORDS:
            if kw in text:
                print(
                    f"[bank-guardrail] DENIED "
                    f"key_alias={key_alias} "
                    f"keyword={kw!r}"
                )
                raise HTTPException(status_code=400, detail=REFUSAL_MESSAGE)
        print(
            f"[bank-guardrail] ALLOW key_alias={key_alias} "
            f"model={data.get('model')}"
        )
        return data

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        try:
            for choice in getattr(response, "choices", []) or []:
                content = getattr(choice.message, "content", None)
                if isinstance(content, str):
                    for pat in PII_PATTERNS:
                        content = re.sub(pat, "[REDACTED]", content)
                    choice.message.content = content
        except Exception as e:
            print(f"[bank-guardrail] redaction error (passing through): {e}")
        return response


proxy_handler_instance = BankGuardrail()
GUARDEOF

# --- Pull secrets from Secrets Manager and write .env ---
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "${db_secret_arn}" --query SecretString --output text)
MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id "${master_key_arn}" --query SecretString --output text)
SALT_KEY=$(aws secretsmanager get-secret-value --secret-id "${salt_key_arn}" --query SecretString --output text)

cat > .env <<ENVEOF
DATABASE_URL=postgresql://litellm:$${DB_PASSWORD}@${db_host}:5432/litellm
LITELLM_MASTER_KEY=$${MASTER_KEY}
LITELLM_SALT_KEY=$${SALT_KEY}
AWS_REGION=us-east-1
ENVEOF

chmod 600 .env

# --- Wait for RDS to be available ---
until aws rds describe-db-instances --db-instance-identifier reserve-bank-db --query 'DBInstances[0].DBInstanceStatus' --output text | grep -q "available"; do
  echo "Waiting for RDS to be available..."
  sleep 30
done

# --- Configure CloudWatch agent ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'AGENTEOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/docker.log",
            "log_group_name": "${cloudwatch_log_group}",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
AGENTEOF

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# --- Start gateway ---
docker compose up -d
