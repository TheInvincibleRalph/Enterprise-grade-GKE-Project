# Run: terraform init -backend-config=backend.hcl

# Create the bucket first:
#   gcloud storage buckets create gs://devops-portfolio-tfstate/ --uniform-bucket-level-access


bucket = "devops-portfolio-tfstate"
prefix = "terraform/state"

