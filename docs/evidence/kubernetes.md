# Local Kubernetes evidence

The isolated kind cluster ran Kubernetes v1.34.0 and two versions of the Linux service. A BusyBox 1.37.0 client called the ClusterIP Service every 0.2 seconds (plus request time). The loop printed FAILED on a request error. It stayed on the cluster through both changes.

```console
$ kubectl set image deployment/app app=assessment-service:1.0.1
deployment.apps/app image updated
$ kubectl rollout status deployment/app
deployment "app" successfully rolled out
$ kubectl rollout undo deployment/app
deployment.apps/app rolled back
$ kubectl rollout status deployment/app
deployment "app" successfully rolled out
```

Of 54 observed responses, 34 reported version 1.0.0 and 20 reported 1.0.1. Zero sampled requests failed. The sampling interval bounds this observation.

```text
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS
app    Deployment/app   cpu: 2%/65%   2         5         2

NAME                   CPU(cores)   MEMORY(bytes)
app-694b789c95-kdj9h   1m           3Mi
app-694b789c95-ttv78   1m           3Mi
```
The first immediate top query returned “metrics not available yet”. The second query above succeeded after the Metrics Server collection interval. This test verified live CPU input. It did not stress the service to its scale-out threshold.
