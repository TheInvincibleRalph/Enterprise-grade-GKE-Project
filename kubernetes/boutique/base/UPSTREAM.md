# Google Online Boutique upstream

The vendored manifest in this directory comes from:

`GoogleCloudPlatform/microservices-demo/release/kubernetes-manifests.yaml`

Pinned source commit:

`72ba613a05f7fcee51cf1d0badff401b6ae7074d`

Vendoring the manifest keeps cluster reconciliation independent of Google's
repository availability and gives Consize a repo-owned source file for
infrastructure-as-code pull requests.

