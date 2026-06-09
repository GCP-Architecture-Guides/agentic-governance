#!/bin/bash
set -e
for PROJ in agentic-security-dev agentic-security-qa agentic-security-prd; do
  SA=""
  if [ "$PROJ" == "agentic-security-dev" ]; then
    # Dev uses the default compute service account for its pipeline
    SA="504643566830-compute@developer.gserviceaccount.com"
    ROLES="roles/owner roles/storage.admin roles/logging.admin roles/monitoring.admin"
  elif [ "$PROJ" == "agentic-security-qa" ]; then
    # QA uses the Cloud Build service account
    SA="717387775586@cloudbuild.gserviceaccount.com"
    ROLES="roles/logging.admin roles/monitoring.admin roles/dlp.admin roles/networksecurity.admin roles/compute.networkAdmin"
  elif [ "$PROJ" == "agentic-security-prd" ]; then
    # PRD uses the Cloud Build service account
    SA="446959546335@cloudbuild.gserviceaccount.com"
    ROLES="roles/logging.admin roles/monitoring.admin roles/dlp.admin roles/networksecurity.admin roles/compute.networkAdmin"
  fi
  
  echo "Granting roles to $SA in $PROJ"
  for ROLE in $ROLES; do
    gcloud projects add-iam-policy-binding "$PROJ" --member="serviceAccount:$SA" --role="$ROLE" --condition=None >/dev/null || true
  done
done
echo "DONE granting roles"
