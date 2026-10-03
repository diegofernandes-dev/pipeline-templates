# ADO compile evidence — v6 candidate (PR #12)

```text
pipeline / preview: diegolab / platform-engineering / sample-api-ci-template-test (id 13)
mechanism: Azure DevOps Pipelines Preview API (api-version 7.1)
templates ref: bbcf29f5bd427833cbbc4e819e0202d0c13aed38
result: PASS
```

## platformArea: lab

Expanded stages:

```text
CI
DeployContract
Container
Deploy_develop
Deploy_homolog
```

```text
Deploy_production: ABSENT
```

Resolution:

```text
Deploy_develop
  pool: PG-AWS-EKS
  ADO Environment: develop
  scheduledJobSmokeEnabled: false
  dependsOn: [Container]

Deploy_homolog
  pool: PG-AWS-EKS-HML
  ADO Environment: homolog
  scheduledJobSmokeEnabled: false
  dependsOn: [Container, Deploy_develop]

Container dependsOn: [CI, DeployContract]
DeployContract dependsOn: [CI]
```

Compile-time lookups proven via expansion:

```text
parameters.platform.promotion[n]
parameters.platform.tiers[promotion[n]].deployPool
parameters.platform.tiers[promotion[n]].environmentName
parameters.platform.tiers[promotion[n]].scheduledJobSmoke.enabled
```

## platformArea: none

```text
expanded stages: CI
DeployContract / Container / Deploy_*: ABSENT
result: PASS
```

## Notes

- No Kubernetes deploy executed for this proof.
- Charts / runtime matrix not rerun.
- `v6.0.0` tag not created; pin the candidate commit SHA until release.
