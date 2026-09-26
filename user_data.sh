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

# --- Clone project ---
cd /opt
git clone https://github.com/privateInferenceAI/reserve-bank-demo-iac.git
cd reserve-bank-demo-iac

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
