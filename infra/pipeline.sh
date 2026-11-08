#!/usr/bin/env bash
# =============================================================================
# Entrega 3 - Pipeline CI/CD con AWS CodePipeline (V2)
#   Source  : GitHub (CodeConnections), rama main, se dispara con cada push
#   Build   : CodeBuild floropitos-cicd -> pytest + docker build + push a ECR
#   Deploy  : CodeDeploy blue/green sobre ECS Fargate (blacklist-cd / blacklist-dg)
# Requiere haber corrido infra/setup.sh antes.
# =============================================================================
set -euo pipefail
export AWS_DEFAULT_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET=floropitos-ci-artifacts-${ACCOUNT_ID}
BRANCH=${BRANCH:-main}

CONNECTION_ARN=${CONNECTION_ARN:-$(aws codeconnections list-connections --provider-type-filter GitHub \
  --query 'Connections[?ConnectionStatus==`AVAILABLE`]|[0].ConnectionArn' --output text)}
echo "Conexion GitHub: $CONNECTION_ARN"

cat > /tmp/pipeline.json <<JSON
{
  "pipeline": {
    "name": "blacklist-pipeline",
    "pipelineType": "V2",
    "executionMode": "QUEUED",
    "roleArn": "arn:aws:iam::${ACCOUNT_ID}:role/blacklistPipelineRole",
    "artifactStore": { "type": "S3", "location": "${BUCKET}" },
    "triggers": [{
      "providerType": "CodeStarSourceConnection",
      "gitConfiguration": {
        "sourceActionName": "Source",
        "push": [{ "branches": { "includes": ["${BRANCH}"] } }]
      }
    }],
    "stages": [
      { "name": "Source", "actions": [{
          "name": "Source",
          "actionTypeId": { "category": "Source", "owner": "AWS", "provider": "CodeStarSourceConnection", "version": "1" },
          "configuration": {
            "ConnectionArn": "${CONNECTION_ARN}",
            "FullRepositoryId": "juandguzCasadiego/proyecto-devops-floropitos",
            "BranchName": "${BRANCH}",
            "OutputArtifactFormat": "CODE_ZIP",
            "DetectChanges": "true"
          },
          "outputArtifacts": [{ "name": "SourceArtifact" }]
      }]},
      { "name": "Build", "actions": [{
          "name": "Pruebas-y-Imagen",
          "actionTypeId": { "category": "Build", "owner": "AWS", "provider": "CodeBuild", "version": "1" },
          "configuration": { "ProjectName": "floropitos-cicd" },
          "inputArtifacts": [{ "name": "SourceArtifact" }],
          "outputArtifacts": [{ "name": "BuildArtifact" }]
      }]},
      { "name": "Deploy", "actions": [{
          "name": "Fargate-BlueGreen",
          "actionTypeId": { "category": "Deploy", "owner": "AWS", "provider": "CodeDeployToECS", "version": "1" },
          "configuration": {
            "ApplicationName": "blacklist-cd",
            "DeploymentGroupName": "blacklist-dg",
            "TaskDefinitionTemplateArtifact": "BuildArtifact",
            "TaskDefinitionTemplatePath": "taskdef.json",
            "AppSpecTemplateArtifact": "BuildArtifact",
            "AppSpecTemplatePath": "appspec.yaml",
            "Image1ArtifactName": "BuildArtifact",
            "Image1ContainerName": "IMAGE1_NAME"
          },
          "inputArtifacts": [{ "name": "BuildArtifact" }]
      }]}
    ]
  }
}
JSON

if aws codepipeline get-pipeline --name blacklist-pipeline >/dev/null 2>&1; then
  aws codepipeline update-pipeline --cli-input-json file:///tmp/pipeline.json >/dev/null && echo "Pipeline actualizado"
else
  aws codepipeline create-pipeline --cli-input-json file:///tmp/pipeline.json >/dev/null && echo "Pipeline creado"
fi
