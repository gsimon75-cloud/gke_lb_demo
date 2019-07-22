# A demo deployment of a load-balanced web example project in Google Kubernetes Engine

## Overview

This small project aims to demonstrate how to set up a load-balanced environment that runs some web application and
incorporates their database backend as well, all these in Google Kubernetes Engine, step by step right from the start.


## Prerequisites

You need an account to the Google Cloud platform (obviously), you shall create a *project* that will enclose all the
resources and entities we'll create (and separate them from your other things).

Then create a Service Account within this project ([Menu / IAM & Accounts / Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts)),
and generate a private key for this account that our mechanisms will use later by clicking the three-dot icon to the
right of the service account, choosing 'Create key' and saving the file, like `service_account.json`.

Then you shall authorize this account to perform certain roles in your project:

* Go to [IAM & Accounts / IAM](https://console.cloud.google.com/iam-admin/iam)
* Choose the service account, click its 'Edit' on the right
* 'Add another role', choose 'Kubernetes Engine' / 'Kubernetes Engine Admin'
* 'Add another role', choose 'Service Accounts' / 'Service Account User'
* Save

Then transfer that `service_account.json` here and tell the gcloud cli to use it:
`gcloud auth activate-service-account --key-file=service_account.json`

Then you can check its results: `gcloud info`, or actually test if it indeed works: `gcloud container clusters list`

If you got error messages, then something is still wrong, but an empty list is completely normal if you don't have any
clusters created yet. (We'll change that soon :) ...)


## Creating the cluster

A cluster consists of a bunch of hosts that run all the Kubernetes stuff, so first we'll need some instances to
do this.

Fortunately we don't need to do this right from the instance-level, because the GKE infrastructure will do all these
for us:
* Provisioning the instances
* Choosing an already Kubernetes-aware OS image for them
* Configuring the cluster store, etc.
* Registering the new instances as parts of the cluster

All we need is to define the parameters of the images and of the cluster:

For the images:

* Machine type
* Disk size

For the cluster:

* Initial number of nodes
* Minimal / maximal number of nodes (if we want autoscaling)
* Whether we want auto-repair and auto-upgrade functionality

It's that simple! Well, almost...


### Some details

In addition to the Cluster there is another entity: the Node Pool. As its name suggests, it contains (and manages) a
bunch of nodes, so actually all those 'for the cluster' parameters belong to a Node Pool, and such Node Pools (note
the plural) belong to a Cluster. In fact, the Cluster adds very little extra to those Pools...

And there is a small limitation here, that causes some inconvenience for us.

Creating a Cluster involves storing a lot of information in its Pools, so we can't create a Cluster without a (default)
Pool. But as of the current state of the APIs, not all Pool parameters can be configured when creating the Cluster, so
we've got a chicken-and-egg problem here.

As of now, the only solution seems to
* Create the Cluster with a minimal Pool
* Create a new Pool with all the features, and assign it to the Cluster
* Dispose of that first, implicitely created minimal 'default' Pool

This may change in the future, as the [Cluster API documentation](https://cloud.google.com/kubernetes-engine/docs/reference/rest/v1/projects.zones.clusters)
marks the `nodeConfig` and `initialNodeCount` fields of the Cluster as obsoleted, and recommends specifying the initial
Pool as part of the Cluster specification (`nodePools[]`), but with the full specification model as any Pools that we
would add afterwards.

So, this is an Ansible limitation, because the latest changes of the GKE API hasn't yet been tracked to the
corresponding module [`gcp_container_cluster`](https://github.com/ansible/ansible/blob/8074fa9a3e388072416238aeeac8eab524442dbd/lib/ansible/modules/cloud/google/gcp_container_cluster.py#L719).
([Others](https://serverfault.com/questions/822787/create-google-container-engine-cluster-without-default-node-pool/823938)
have also run into this problem, only at that time the new GKE API may not have existed yet.)

As of that initial 'minimal pool', GKE also has some peculiar restrictions: if we chose the smallest machine type
(`f1-micro`), it would require at least 3 of them to form a Node Pool, therefore we have to choose the next smallest
(`g1-small`), of which one is enough.


### Actually creating the cluster

We have an Ansible playbook for that: `./run.sh 0_create_cluster.yaml`


### Checking the cluster

When we want to manage the cluster manually, we'll use the CLI tool `kubectl`, which needs access to the cluster, but
that has already taken care of by the playbook, it fetched the cluster credentials and placed it to `~/.kube/config`,
which will be used by `kubectl`.

To check that we can actually access the cluster: `kubectl cluster-info`


## Misc notes

### Time overhead because of the 'Cluster vs. Pool' creation problem

* Creating the cluster with the implicite pool (1 g1-small with 10GB disk, no autoscaling, no auto-repair, no auto-upgrade): 2.5 minutes
* Creating the real pool (4 f1-micro instances with 10GB disks): 5.5 minutes
* Deleting the implicite pool: 2 minutes

It seems that the time overhead caused by the implicite pool (creating and destroying it) is about 3 minutes.
That's not negligible, but not insufferable either.


### Contents of `~/.kube/config`

It's a .yaml file with the following information:

`fullname = "gke_{{ project_id }}_{{ zone }}_{{ cluster_name }}"`

```
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: "{{ cluster.masterAuth.clusterCaCertificate }}"
    server: "https://{{ cluster.endpoint }}"
  name: "{{ fullname }}"
contexts:
- context:
    cluster: "{{ fullname }}"
    user: "{{ fullname }}"
  name: "{{ fullname }}"
current-context: "{{ fullname }}"
kind: Config
preferences: {}
users:
- name: "{{ fullname }}"
  user:
    auth-provider:
      config:
        cmd-args: config config-helper --format=json
        cmd-path: /usr/lib64/google-cloud-sdk/bin/gcloud
        expiry-key: '{.credential.token_expiry}'
        token-key: '{.credential.access_token}'
      name: gcp
```
