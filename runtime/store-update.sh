#!/bin/sh
# The runtime image's store-update program: once per container start, then it stays down.
#
# What the Hermes image's s6 store-update service did, minus the Hermes-specific half: the store
# update (`ctxr-update-store`, on unless CTXR_UPDATE_STORE_ENABLED is off), then every installed
# harness's `store-updated` hook, which runs either way -- turning the store update off must not
# strand a stale copy of something a harness took from the store (Hermes' Circleback runner).
# Never fails the boot: supervisord runs it with autorestart=false, and it exits 0.
case "${CTXR_UPDATE_STORE_ENABLED:-1}" in
  0|false|FALSE|False|no|NO|No|off|OFF|Off) ;;
  *) ctxr-update-store || echo "runtime-store-update: ctxr-update-store exited $?" ;;
esac
harness-install hook store-updated || echo "runtime-store-update: a store-updated hook failed"
exit 0
