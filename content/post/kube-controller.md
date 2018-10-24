+++
date        = "2018-09-05T13:03:00+02:00"
title       = "What I learnt about Kubernetes Controllers"
description = "Some stuff I learnt about kubernetes controllers while working on an issue around Storage"
slug        = "what-i-learnt-about-kubernetes-controller"
image       = "/gdb-go/gdb-dashboard.jpg"
+++

If you are a Kubernetes Controller you know that your main duty is to react to changes to the world’s desired state and actual state to do whatever you can to update the latter so that it matches the former.

When I think about my early steps with Kubernetes two things comes to mind related to Controllers:

- That everyone used the `ReplicationController` because we didn’t have `Deployment`
- The hard times to have the controller manager working in my clusters.

Said that, I was sure I knew everything about controllers myself but just realized I never had the opportunity to learn what they actually do underneath until recently when I had a peak of interest after opening issue [#67342](https://github.com/kubernetes/kubernetes/issues/67342) titled “Storage: devicePath is empty while WaitForAttach in StatefulSets”.

While trying to reproduce, I encountered a set of call to functions that were happening through some files named with very explanatory names:

```
actual_state_of_world.go:616 ->
  reconciler.go:238 ->
    operation_executor.go:712 ->
       operation_generator.go:437 -> error on line 496
```

This looked very similar to a definition I found in the *"Standardized Glossary"* here.


> A control loop that watches the shared state of the cluster through the apiserver and makes changes attempting to move the current state towards the desired state.
> Examples of controllers that ship with Kubernetes today are the replication controller, endpoints controller, namespace controller, and serviceaccounts controller.

Nice so the [`VolumeManager`](https://github.com/kubernetes/kubernetes/blob/6cc7b1cd3aac5c9abd6fc1416b16f9c141b6ff14/pkg/kubelet/volumemanager/volume_manager.go#L98) is not really a controller but conceptually it behaves in a very similar way since it has a loop, a reconciler, a desired state and an actual state.

At this point I started looking at all the projects both private and public I touched and among the public ones I recognized a very interesting pattern they all had a `cache.ListWatch` and a `cache.SharedInformer`.

The interesting part was that most of them also had a `workqueue.Interface` like the [etcd operator controller](https://github.com/coreos/etcd-operator/blob/c8f63d508266990a4d20718d94363c30e75e6282/pkg/controller/backup-operator/controller.go#L37), the [NGINX ingress controller](https://github.com/kubernetes/ingress-nginx/blob/29c5d770688b04d0a8beedf70aebd76990332d56/internal/task/queue.go#L41) and the [OpenFaas Operator Controller](https://github.com/openfaas-incubator/openfaas-operator/blob/a928752c5cd0429330c9474b834ea63d29741185/pkg/controller/controller.go#L66) and it turns out that they use it because it’s a key component in ensuring that the state is consistent and that all the controller’s instances agree on a shared set of elements to be processed with certain constraints (this looks very close to that Glossary’s definition above!).


While writing this post I was tempted to write a full length example but I found an already available [exhaustive example](https://github.com/kubernetes/kubernetes/tree/53ee0c86522b1afc1ee64503c73965b89d500db5/staging/src/k8s.io/sample-controller) in the kubernetes repo so i will just write and go through the simplest self-contained example I can write.


Scroll to the end of the controller example to read about it.


<script src="https://gist.github.com/fntlnz/65ec4e7273b15e858dda97c0f6f2241b.js"></script>

The main components of this Controller are:

- The Workqueue (I would say, the reconciler or the thing that coordinates the synchronization from the actual state of the world to the desired state of the world)
- `syncToStdout`: The logic used to make changes to the actual state of the world
- The SharedInformer: From the glossary’s definition — A control loop that watches the shared state

In the SharedInformer I define some handlers to deal with `Add`, `Delete` and `Update` but instead of using them directly I synchronize what they receive into a workqueue with `queue.Add`

```go
AddFunc: func(obj interface{}) {
   key, err := cache.MetaNamespaceKeyFunc(obj)
   if err == nil {
    queue.Add(key)
   }
 },
```


The Workqueue is a structure that allows to queue changes for a specific resource and process them later in multiple workers with the guarantee that there will be no more than one worker working on a specific item at the same moment.
In fact the elements are processed in `runWorker` and multiple workers are started by increasing the `threadiness` parameter of the Controller’s Run method.

In this way I can end up in `syncToStdout` and be sure I will be the only one processing that item while knowing that if the current process gives an error my operation will be repeated up to an hardcoded limit of 5 times as defined in `handleErr`.

In this situation every item has an exponential backoff rate limit so that failures are not retried immediately but after a calculated amount of time that increases depending on the specified factor (I used DefaultControllerRateLimiter here but it’s very easy to create your own with chosen parameters).

This rate limit mechanism can be very helpful if we added a call to an external API every time we are informed about a pod. In such case the external API might impose a rate limit to our calls resulting in a failed behavior right now that will be perfectly fine after retrying in a while.

The Indexer and the Informer are also key components to use the process workqueue elements here because we want to be Informed about events occurring for the resources Kind we are interested in (in this case: Pod) and we want to have an Index where we can lookup for the final Pod object.

But hey, since we used the SharedInformer so we don’t need to provide an indexer ourselves because our beloved informer already contains one in `GetStore()`.


Another aspect of using the SharedInformer here is that we are guaranteed that the element we get from its internal indexer is at least as fresh as the event we received.

Wow, I don’t think I know everything about controllers now but I’m still in the peak of interest so I will probably follow with more stuff on the topic.
