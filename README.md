# A demo deployment of a load-balanced web example project in Google Kubernetes Engine

## Overview

This small project aims to demonstrate how to set up a load-balanced environment that runs some web application and
incorporates their database backend as well, all these in Google Kubernetes Engine, step by step right from the start.

It looks a simple case, but believe me, there were quite some unexpected obstacles along the way...


## Prerequisites

You need an account to the Google Cloud platform (obviously), you shall create a *project* that will enclose all the
resources and entities we'll create (and separate them from your other things).

### A GCP Service Account

Then create a Service Account within this project ([Menu / IAM & Accounts / Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts)),
and generate a private key for this account that our mechanisms will use later by clicking the three-dot icon to the
right of the service account, choosing 'Create key' and saving the file, like `service_account.json`.

Then you shall authorize this account to perform certain roles in your project:

* Go to [IAM & Accounts / IAM](https://console.cloud.google.com/iam-admin/iam)
* Choose the service account, click its 'Edit' on the right
* 'Add another role', choose 'Kubernetes Engine' / 'Kubernetes Engine Admin'
* 'Add another role', choose 'Service Accounts' / 'Service Account User'
* 'Add another role', choose 'Storage' / 'Storage Admin'
* Save

Then transfer that `service_account.json` here and tell the gcloud cli to use it:
`gcloud auth activate-service-account --key-file=service_account.json`

Then you can check its results: `gcloud info`, or actually test if it indeed works: `gcloud container clusters list`

If you got error messages, then something is still wrong, but an empty list is completely normal if you don't have any
clusters created yet. (We'll change that soon :) ...)

### Docker

We'll need to manipulate Docker images, so Docker must be installed, enabled and started.


### OS packages

docker, kubectl

python2-google-auth, python2-libcloud, python2-crypto, python2-openshift, python-netaddr, python-docker-py


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
Pool. But as of the current state of the Ansible module `gcp_container_cluster`, not all Pool parameters can be
configured through it. But we can't create the Pool first, without the Cluster, so we've got a chicken-and-egg problem
here.

As of now, the only solution seems to
* Create the Cluster with a minimal Pool
* Create a new Pool with all the features, and assign it to the Cluster
* Dispose of that first, implicitely created minimal 'default' Pool

This may change in the future, as the [Cluster API documentation](https://cloud.google.com/kubernetes-engine/docs/reference/rest/v1/projects.zones.clusters)
marks the `nodeConfig` and `initialNodeCount` fields of the Cluster as obsoleted, and recommends specifying the initial
Pool as part of the Cluster specification (`nodePools[]`), but with the full specification model as any Pools that we
would add afterwards.

So, this is an Ansible limitation, the latest changes of the GKE API hasn't yet been tracked to the
corresponding module [`gcp_container_cluster`](https://github.com/ansible/ansible/blob/8074fa9a3e388072416238aeeac8eab524442dbd/lib/ansible/modules/cloud/google/gcp_container_cluster.py#L719).
([Others](https://serverfault.com/questions/822787/create-google-container-engine-cluster-without-default-node-pool/823938)
have also run into this problem, only at that time the new GKE API may not have existed yet.)

As of that initial 'minimal pool', GKE also has some peculiar restrictions: if we chose the smallest machine type
(`f1-micro`), it would require at least 3 of them to form a Node Pool, therefore we have to choose the next smallest
(`g1-small`), of which one is enough.

#### Note #1

If the script cannot dump the cluster services, but returns a terse `Unauthorized` error, then check on the web
console if the cluster could indeed start up, or is it standing in a 'Pods unschedulable' state.

#### Note #2

If we drop a node pool while the auto-upgrade is in progress, then we'll get that 'Pods unschedulable' above.
That's why the auto-upgrade option is disabled in the creator playbook.


### Actually creating the cluster

We have an Ansible playbook for that: `./run.sh 0_create_cluster.yaml`


### Checking the cluster

When we want to manage the cluster manually, we'll use the CLI tool `kubectl`, which needs access to the cluster, so
we must tell it to ask `gcloud` for credentials.

This information must be described in `~/.kube/config` in quite a nice syntax, but `gcloud` can do that for us:

`gcloud container clusters get-credentials --zone=europe-west1-c lb-demo-cluster`

Then, to check that we can actually access the cluster: `kubectl cluster-info`

NOTE: This `~/.kube/config` is only needed for `kubectl`, as the playbooks access and use the credentials directly.


## Deploying MariaDB

### The container image

GKE has its own [container registries](https://cloud.google.com/container-registry/docs/managing) like `gcr.io`,
`eu.gcr.io`, `asia.gcr.io`, `k8s.gcr.io`, even `mirror.gcr.io` that
[mirrors](https://cloud.google.com/container-registry/docs/using-dockerhub-mirroring) *some* of the Docker Hub
images.

`mariadb/server` is not among them, so we'll have to copy it to our own project-scope registry: pull from the original
registry, tag it, and push it to our registry.

To push a local image to a GSE storage, the [officially recommended way](https://cloud.google.com/container-registry/docs/pushing-and-pulling)
is to do it via `docker`:

1. Pull the original image: `docker pull mariadb/server`
2. Add a tag that refers to our project registry: `docker tag mariadb/server eu.gcr.io/networksandbox-232012/mariadb/server`
3. Push the image: `docker push eu.gcr.io/networksandbox-232012/mariadb/server`

Pushing needs some credentials, so the documentation recommends configuring `docker` to use `gcloud` as a credential
store: `gcloud auth configure-docker --quiet`, but **DON'T** do it yet. It wouldn't work as expected, so we'll have a
workaround and therefore we won't need it.

(Btw, this command would just create/update `~/.docker/config.json` with `{ "credHelpers": { "gcr.io": "gcloud", ... }`,
so it's not dealing with the credentials, it only configures how to get them.)


### `docker` as non-root

We are working as a plain, non-root user, so just saying `docker whatever` will only give us some error messages about
not being able to write `/var/run/docker.sock`.

There is a [doc](https://docs.docker.com/install/linux/linux-postinstall/) on how to configure Docker accessible for
non-root users, and there is [another doc](https://docs.docker.com/engine/security/security/#docker-daemon-attack-surface)
about why not to do it.

Starting from Centos 7, the OS-supported `docker` packages follow the 'root-only' discipline and tell that if you want to
make `docker` available for non-root users, then configure `sudo` for them, because it's at least audited, while the
implicit (and needed) root-exec abilities of `docker` aren't.

At first glance there isn't too much difference between `docker whatever` and `sudo docker whatever`, and for the `pull`
and `tag` commands it indeed would work. For the `push`, however, it wouldn't.


### `docker` vs. `gcloud`

If we told `gcloud` to tell `docker` to use `gcloud` as credential source (that `gcloud auth configure-docker`
above), it would create/update the `.docker/config.json` in **our** home folder.

Then when we'd say `sudo docker push ...`, the `docker` command would run as root and use the home folder of root, and
thus wouldn't even consider **our** `config.json`.

This could be circumvented by telling `docker` where to look for its config: `sudo docker --config "$HOME/.docker" push ...`,
and it *almost* works. Almost...

The docker client can connect to the socket, talk to the docker daemon, prepare the images to send, but then it fails:

`denied: Token exchange failed for project 'networksandbox-232012'. Caller does not have permission 'storage.buckets.get'. To configure permissions, follow instructions at: https://cloud.google.com/container-registry/docs/access-control`

The problem is this:

1. `docker push` is running as root
2. It starts talking with the GSE server, reaches the authentication phase
3. Calls out to `gcloud` for credentials, **still as root**
4. So `gcloud` is also running as root
5. It tries to get its active config and such information from `~/.config/gcloud/`
6. That refers to the home folder of root, and **not to ours**
7. There certainly are no credentials for our logged-in service account

(It took about two hours of debugging the scripts and tracing `docker` with `strace`, but finally managed to catch it :D !)


### The solution

What `docker` actually does when asking `gcloud` for credentials is like this: `echo "https://eu.gcr.io" | gcloud auth docker-helper get`,
and expects the credentials in .json format: `{ "Secret": "...", "Username": "_dcgcloud_token" }`

That is the username and password `docker` uses to access the server `eu.gcr.io`, so we may as well login
there with these credentials: `sudo docker login -u "_dcgcloud_token" -p "..." eu.gcr.io`.

The token has a limited validity period, so it should be performed right before the `sudo docker push ...`, but then
all the `sudo docker ...` commands work fine, and finally we can log out as well: `sudo docker logout https://eu.gcr.io`

NOTE: This token is the same as that in the structure returned by `gcloud config config-helper --format=json`, so the
playbook uses that one.


### Summary

1. Pull the original image: `sudo docker pull mariadb/server`
2. Add a tag that refers to our project registry: `sudo docker tag mariadb/server eu.gcr.io/networksandbox-232012/mariadb/server`
3. Logout any previous logins: `sudo docker logout eu.gcr.io`
4. Get a fresh token: `echo "https://eu.gcr.io" | gcloud auth docker-helper get`
5. Login to the server: `sudo docker login -u "_dcgcloud_token" -p "..." eu.gcr.io`
6. Push the image: `docker push eu.gcr.io/networksandbox-232012/mariadb/server`
7. Logout: `sudo docker logout eu.gcr.io`

This is done by `1_clone_mariadb_image.yaml`, and then its result can be checked: 

`gcloud container images list --repository=eu.gcr.io/networksandbox-232012/mariadb`


## Misc notes

### Time overhead because of the 'Cluster vs. Pool' creation problem

* Creating the cluster with the implicite pool (1 g1-small with 10GB disk, no autoscaling, no auto-repair, no auto-upgrade): 2.5 minutes
* Creating the real pool (4 f1-micro instances with 10GB disks): 5.5 minutes
* Deleting the implicite pool: 2 minutes

It seems that the time overhead caused by the implicite pool (creating and destroying it) is about 3 minutes.
That's not negligible, but not insufferable either.


### SSL handling of `k8s_facts`

There is a [bug](https://github.com/ansible/ansible/issues/56640), it was [fixed](https://github.com/ansible/ansible/pull/57418),
the fix was merged in on Jun 5, 2019. '2.8.1' was released on Jun 7 but it doesn't have the fix, neither does '2.8.2',
so probably it'll be released in '2.8.3'.

Until then, apply [this](https://github.com/ansible/ansible/issues/56640#issuecomment-496526804) workaround.


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

So the actual auth credentials are provided by `gcloud config config-helper --format=json`, which produces

```
{
  "configuration": {
    "active_configuration": "default",
    "properties": {
      "core": {
        "account": "...@....",
        "disable_usage_reporting": "True",
        "project": "networksandbox-232012"
      }
    }
  },
  "credential": {
    "access_token": "...",
    "token_expiry": "2019-07-23T10:54:19Z"
  },
  "sentinels": {
    "config_sentinel": ".../.config/gcloud/config_sentinel"
  }
}
```

That `access_token` is the same as the one returned by `echo "https://gcr.io" | gcloud auth docker-helper get`
