#!/usr/bin/env bash
# Post-renderer script to extract only CRDs from Helm charts
yq eval-all --exit-status 'select(.kind == "CustomResourceDefinition")'
