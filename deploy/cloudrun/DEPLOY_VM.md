# Triển khai PR-Agent GitHub App lên GCE VM với Secret Manager

## 1) Tạo secrets manager trên GCP

```bash
# Ở local
# Check
gcloud --version

# Nếu chưa có
sudo apt update
sudo apt install -y google-cloud-cli

# Kiểm tra project id trên VM
gcloud config get-value project

#Thay id project vào
export PROJECT_ID=<PROJECT_ID>

# Config set project
gcloud config set project <PROJECT_ID>

# Bật service
gcloud services enable secretmanager.googleapis.com

# Bật service secret manager
gcloud services enable secretmanager.googleapis.com --project "$PROJECT_ID"
```

- Tạo secrets key vào secrets manager

```bash
# Vẫn trên local

printf '%s' '<OPENAI_KEY>' | gcloud secrets create pr-agent-openai-key \
  --project "$PROJECT_ID" --data-file=-

printf '%s' '<GITHUB_APP_ID>' | gcloud secrets create pr-agent-github-app-id \
  --project "$PROJECT_ID" --data-file=-

gcloud secrets create pr-agent-github-private-key \
  --project "$PROJECT_ID" --data-file=/path/to/github-app-private-key.pem

printf '%s' 'e8f5905d2d6f886a08fc8d5868a456febf2728823cbc0f9cf0bd577a0541cf60' | gcloud secrets create pr-agent-github-webhook-secret \
  --project "$PROJECT_ID" --data-file=-

# Kiểm tra list
gcloud secrets list
```

- Kết quả đạt chuẩn:

```yaml
khvavuong@vuongkv-Inspiron-15-3511:~$ gcloud secrets list
NAME                            CREATED              REPLICATION_POLICY  LOCATIONS
pr-agent-github-app-id          2026-05-27T19:01:54  automatic           -
pr-agent-github-private-key     2026-05-27T19:03:33  automatic           -
pr-agent-github-webhook-secret  2026-05-27T19:02:23  automatic           -
pr-agent-openai-key             2026-05-27T19:01:05  automatic           -
```

## 2) Gán quyền Secret Manager cho VM E2

Vẫn trên máy local, lấy service account của VM:

```bash
export PROJECT_ID=<PROJECT_ID>
export VM_NAME=pr-agent
export VM_ZONE=us-central1-a

# Lấy service account VM
VM_SA=$(gcloud compute instances describe "$VM_NAME" \
  --zone "$VM_ZONE" \
  --project "$PROJECT_ID" \
  --format='value(serviceAccounts[0].email)')

echo "$VM_SA"
```

Gán quyền đọc secret:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/secretmanager.secretAccessor"
```

Kiểm tra trên VM:

```bash
gcloud secrets versions access latest \
--secret=pr-agent-openai-key
```

## 3) Build image artifact ở local

```bash
cd /home/khvavuong/Documents/Langgraph/pr-agent/pr-agent
./deploy/cloudrun/deploy_github.sh package
```

Artifact tạo ra:

```text
deploy/packages/pr-agent-github-<version>.tar.gz
```

## 4) Copy artifact và script lên VM

```bash
cd /home/khvavuong/Documents/Langgraph/pr-agent/pr-agent

gcloud compute scp \
  deploy/packages/pr-agent-github-*.tar.gz \
  deploy/cloudrun/deploy_github.sh \
  "$VM_NAME":~/ \
  --zone "$VM_ZONE" \
  --project "$PROJECT_ID"
```

## 5) Deploy trên VM

```bash
gcloud compute ssh "$VM_NAME" --zone "$VM_ZONE" --project "$PROJECT_ID"

chmod +x ~/deploy_github.sh

# Lệnh này chuẩn
sudo GCP_PROJECT_ID=project-1d9ef75c-8b9c-44bc-96e \
BUNDLE_NAME=pr-agent-github-20260528-013800.tar.gz \
BUNDLE_PATH=/opt/pr-agent/pr-agent-github-20260528-013800.tar.gz \
bash deploy_github.sh run

# Lệnh xịn nếu ngon
GCP_PROJECT_ID=<PROJECT_ID> bash ~/deploy_github.sh run
```

## 6) Cấu hình GitHub App webhook

Webhook URL:

```text
https://<your-domain>/api/v1/github_webhooks
```

Webhook Secret:

```text
giá trị trong secret `pr-agent-github-webhook-secret`
```

Cài GitHub App vào repo cần dùng, ví dụ `khvavuong/pr-test`.

## 7) Kiểm tra trên VM

```bash
sudo docker ps
sudo docker logs -f pr-agent-github
curl -i http://127.0.0.1:3000/
```

## 8) Firewall và HTTPS

Nếu expose trực tiếp port 3000:

```bash
gcloud compute firewall-rules create allow-pr-agent-3000 \
  --allow tcp:3000 \
  --target-tags <VM_NETWORK_TAG> \
  --project "$PROJECT_ID"
```

Khuyến nghị production: dùng Nginx hoặc Caddy cho HTTPS, proxy vào `127.0.0.1:3000`.

```

```
