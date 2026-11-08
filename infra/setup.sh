#!/usr/bin/env bash
# =============================================================================
# Entrega 3 - Infraestructura del microservicio en AWS Fargate (us-east-1)
# Se ejecuta en AWS CloudShell. Crea:
#   ECR, grupos de seguridad, RDS PostgreSQL, parametros SSM, roles IAM,
#   ALB con dos target groups (blue/green), cluster y servicio ECS Fargate
#   (controlador CODE_DEPLOY), aplicacion y grupo de despliegue de CodeDeploy,
#   y el proyecto de CodeBuild que usa el pipeline.
# El despliegue inicial (manual) usa una imagen construida aqui mismo.
# Uso:  bash setup.sh            (todo)
#       bash setup.sh <paso>     (un paso: ecr|net|rds|ssm|iam|logs|alb|image|ecs|codedeploy|codebuild|out)
# =============================================================================
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-1
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
APP=blacklist
REPO_NAME=blacklist-app
CLUSTER=blacklist-cluster
SERVICE=blacklist-service
CONTAINER=blacklist-app
PORT=5000
GITHUB_REPO=https://github.com/juandguzCasadiego/proyecto-devops-floropitos
ARTIFACT_BUCKET=floropitos-ci-artifacts-${ACCOUNT_ID}
STATE=$HOME/blacklist-infra.env
touch "$STATE"; source "$STATE"
save() { grep -v "^$1=" "$STATE" > "$STATE.tmp" || true; mv "$STATE.tmp" "$STATE"; echo "$1=${2:-}" >> "$STATE"; export "$1=${2:-}"; }
log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  --query 'Subnets[?AvailabilityZone!=`us-east-1e`].SubnetId' --output text)
SUBNET_CSV=$(echo $SUBNETS | tr ' ' ',')

step_ecr() {
  log "ECR: repositorio $REPO_NAME"
  aws ecr describe-repositories --repository-names $REPO_NAME >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name $REPO_NAME --image-scanning-configuration scanOnPush=true >/dev/null
  aws ecr put-lifecycle-policy --repository-name $REPO_NAME --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"Conservar las ultimas 15 imagenes","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":15},"action":{"type":"expire"}}]}' >/dev/null
}

sg() { # nombre descripcion
  local id
  id=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$1 Name=vpc-id,Values=$VPC_ID --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ]; then id=$(aws ec2 create-security-group --group-name $1 --description "$2" --vpc-id $VPC_ID --query GroupId --output text); fi
  echo $id
}
ingress() { aws ec2 authorize-security-group-ingress "$@" >/dev/null 2>&1 || true; }

step_net() {
  log "Grupos de seguridad"
  save ALB_SG $(sg blacklist-alb-sg "ALB publico del microservicio")
  save ECS_SG $(sg blacklist-ecs-sg "Tareas Fargate del microservicio")
  save RDS_SG $(sg blacklist-rds-sg "PostgreSQL del microservicio")
  ingress --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
  ingress --group-id $ALB_SG --protocol tcp --port 8080 --cidr 0.0.0.0/0
  ingress --group-id $ECS_SG --protocol tcp --port $PORT --source-group $ALB_SG
  ingress --group-id $RDS_SG --protocol tcp --port 5432 --source-group $ECS_SG
}

step_rds() {
  log "RDS PostgreSQL (tarda ~8 minutos)"
  aws rds describe-db-subnet-groups --db-subnet-group-name $APP-db-subnets >/dev/null 2>&1 || \
    aws rds create-db-subnet-group --db-subnet-group-name $APP-db-subnets --db-subnet-group-description "Subredes RDS blacklist" --subnet-ids $SUBNETS >/dev/null
  if ! aws rds describe-db-instances --db-instance-identifier $APP-db >/dev/null 2>&1; then
    save DB_PASSWORD $(openssl rand -hex 16)
    aws rds create-db-instance --db-instance-identifier $APP-db --engine postgres \
      --db-instance-class db.t4g.micro --allocated-storage 20 --storage-type gp3 \
      --master-username postgres --master-user-password "$DB_PASSWORD" --db-name blacklist \
      --vpc-security-group-ids $RDS_SG --db-subnet-group-name $APP-db-subnets \
      --no-publicly-accessible --backup-retention-period 0 --no-multi-az >/dev/null
  fi
  aws rds wait db-instance-available --db-instance-identifier $APP-db
  save DB_HOST $(aws rds describe-db-instances --db-instance-identifier $APP-db --query 'DBInstances[0].Endpoint.Address' --output text)
}

step_ssm() {
  log "Parametros SSM (secretos de la aplicacion)"
  [ -n "${JWT_SECRET:-}" ] || save JWT_SECRET $(openssl rand -hex 32)
  aws ssm put-parameter --name /blacklist/DATABASE_URL --type SecureString --overwrite \
    --value "postgresql+psycopg2://postgres:${DB_PASSWORD}@${DB_HOST}:5432/blacklist" >/dev/null
  aws ssm put-parameter --name /blacklist/JWT_SECRET_KEY --type SecureString --overwrite --value "$JWT_SECRET" >/dev/null
}

role() { # nombre servicio
  aws iam get-role --role-name $1 >/dev/null 2>&1 || aws iam create-role --role-name $1 \
    --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$2\"},\"Action\":\"sts:AssumeRole\"}]}" >/dev/null
}

step_iam() {
  log "Roles IAM"
  role blacklistTaskExecutionRole ecs-tasks.amazonaws.com
  aws iam attach-role-policy --role-name blacklistTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name blacklistTaskExecutionRole --policy-name leer-parametros-ssm --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameters\"],\"Resource\":\"arn:aws:ssm:$REGION:$ACCOUNT_ID:parameter/blacklist/*\"}]}"

  role blacklistCodeDeployRole codedeploy.amazonaws.com
  aws iam attach-role-policy --role-name blacklistCodeDeployRole --policy-arn arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS

  role blacklistCodeBuildRole codebuild.amazonaws.com
  aws iam attach-role-policy --role-name blacklistCodeBuildRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
  aws iam put-role-policy --role-name blacklistCodeBuildRole --policy-name codebuild-base --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:GetObjectVersion\",\"s3:PutObject\",\"s3:GetBucketLocation\",\"s3:GetBucketAcl\"],\"Resource\":[\"arn:aws:s3:::$ARTIFACT_BUCKET\",\"arn:aws:s3:::$ARTIFACT_BUCKET/*\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"codebuild:CreateReportGroup\",\"codebuild:CreateReport\",\"codebuild:UpdateReport\",\"codebuild:BatchPutTestCases\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"codeconnections:UseConnection\",\"codestar-connections:UseConnection\",\"codeconnections:GetConnectionToken\",\"codeconnections:GetConnection\"],\"Resource\":\"*\"}]}"

  role blacklistPipelineRole codepipeline.amazonaws.com
  aws iam put-role-policy --role-name blacklistPipelineRole --policy-name pipeline --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:GetObjectVersion\",\"s3:PutObject\",\"s3:GetBucketVersioning\",\"s3:GetBucketLocation\"],\"Resource\":[\"arn:aws:s3:::$ARTIFACT_BUCKET\",\"arn:aws:s3:::$ARTIFACT_BUCKET/*\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"codeconnections:UseConnection\",\"codestar-connections:UseConnection\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"codebuild:StartBuild\",\"codebuild:BatchGetBuilds\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"codedeploy:CreateDeployment\",\"codedeploy:GetDeployment\",\"codedeploy:GetApplication\",\"codedeploy:GetApplicationRevision\",\"codedeploy:RegisterApplicationRevision\",\"codedeploy:GetDeploymentConfig\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"ecs:RegisterTaskDefinition\",\"ecs:DescribeTaskDefinition\",\"ecs:DescribeServices\",\"ecs:TagResource\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"*\",\"Condition\":{\"StringEqualsIfExists\":{\"iam:PassedToService\":[\"ecs-tasks.amazonaws.com\"]}}}]}"
  sleep 10
}

step_logs() {
  log "CloudWatch Logs /ecs/blacklist"
  aws logs create-log-group --log-group-name /ecs/blacklist 2>/dev/null || true
  aws logs put-retention-policy --log-group-name /ecs/blacklist --retention-in-days 14
}

step_alb() {
  log "Application Load Balancer + target groups blue/green"
  save ALB_ARN $(aws elbv2 create-load-balancer --name blacklist-alb --type application --scheme internet-facing \
    --subnets $SUBNETS --security-groups $ALB_SG --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  save ALB_DNS $(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
  for c in blue green; do
    arn=$(aws elbv2 create-target-group --name blacklist-tg-$c --protocol HTTP --port $PORT --vpc-id $VPC_ID \
      --target-type ip --health-check-path /health --health-check-interval-seconds 15 --healthy-threshold-count 2 \
      --unhealthy-threshold-count 3 --matcher HttpCode=200 --query 'TargetGroups[0].TargetGroupArn' --output text)
    aws elbv2 modify-target-group-attributes --target-group-arn $arn --attributes Key=deregistration_delay.timeout_seconds,Value=15 >/dev/null
    save TG_$(echo $c | tr a-z A-Z) $arn
  done
  save LISTENER_PROD $(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[?Port==`80`].ListenerArn' --output text)
  [ -n "$LISTENER_PROD" ] || save LISTENER_PROD $(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_BLUE --query 'Listeners[0].ListenerArn' --output text)
  save LISTENER_TEST $(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[?Port==`8080`].ListenerArn' --output text)
  [ -n "$LISTENER_TEST" ] || save LISTENER_TEST $(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 8080 \
    --default-actions Type=forward,TargetGroupArn=$TG_GREEN --query 'Listeners[0].ListenerArn' --output text)
}

step_image() {
  log "Construccion y publicacion manual de la imagen inicial"
  local uri=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME
  rm -rf ~/src && git clone -q --branch ${BRANCH:-main} $GITHUB_REPO ~/src
  aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
  local tag=manual-$(git -C ~/src rev-parse --short HEAD)
  docker build -t $uri:$tag ~/src && docker push $uri:$tag
  save INITIAL_IMAGE $uri:$tag
}

step_ecs() {
  log "Cluster, definicion de tarea y servicio ECS Fargate"
  aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 || true
  aws ecs create-cluster --cluster-name $CLUSTER --capacity-providers FARGATE --settings name=containerInsights,value=disabled >/dev/null
  sed "s#<IMAGE1_NAME>#$INITIAL_IMAGE#" ~/src/taskdef.json > /tmp/taskdef.json
  save TASKDEF_ARN $(aws ecs register-task-definition --cli-input-json file:///tmp/taskdef.json --query 'taskDefinition.taskDefinitionArn' --output text)
  if [ "$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].status' --output text)" != "ACTIVE" ]; then
    aws ecs create-service --cluster $CLUSTER --service-name $SERVICE --task-definition $TASKDEF_ARN \
      --desired-count 1 --launch-type FARGATE --deployment-controller type=CODE_DEPLOY \
      --health-check-grace-period-seconds 60 \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_CSV],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
      --load-balancers targetGroupArn=$TG_BLUE,containerName=$CONTAINER,containerPort=$PORT >/dev/null
  fi
  echo "Esperando a que el servicio quede estable..."
  # (el waiter services-stable no funciona con el controlador CODE_DEPLOY)
  until [ "$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].runningCount' --output text)" -ge 1 ]; do sleep 15; done
}

step_codedeploy() {
  log "CodeDeploy: aplicacion y grupo de despliegue blue/green"
  aws deploy get-application --application-name blacklist-cd >/dev/null 2>&1 || \
    aws deploy create-application --application-name blacklist-cd --compute-platform ECS >/dev/null
  aws deploy get-deployment-group --application-name blacklist-cd --deployment-group-name blacklist-dg >/dev/null 2>&1 || \
  aws deploy create-deployment-group --application-name blacklist-cd --deployment-group-name blacklist-dg \
    --service-role-arn arn:aws:iam::$ACCOUNT_ID:role/blacklistCodeDeployRole \
    --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
    --deployment-style deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL \
    --blue-green-deployment-configuration "terminateBlueInstancesOnDeploymentSuccess={action=TERMINATE,terminationWaitTimeInMinutes=1},deploymentReadyOption={actionOnTimeout=CONTINUE_DEPLOYMENT,waitTimeInMinutes=0}" \
    --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE \
    --ecs-services clusterName=$CLUSTER,serviceName=$SERVICE \
    --load-balancer-info "targetGroupPairInfoList=[{targetGroups=[{name=blacklist-tg-blue},{name=blacklist-tg-green}],prodTrafficRoute={listenerArns=[$LISTENER_PROD]},testTrafficRoute={listenerArns=[$LISTENER_TEST]}}]" >/dev/null
}

step_codebuild() {
  log "CodeBuild: proyecto floropitos-cicd (fuente CODEPIPELINE, modo privilegiado para Docker)"
  aws codebuild batch-get-projects --names floropitos-cicd --query 'projects[0].name' --output text | grep -q floropitos-cicd || \
  aws codebuild create-project --name floropitos-cicd \
    --description "CI (pytest) + construccion de imagen Docker para Fargate" \
    --source type=CODEPIPELINE,buildspec=buildspec.yml --artifacts type=CODEPIPELINE \
    --environment "type=LINUX_CONTAINER,image=aws/codebuild/amazonlinux-x86_64-standard:6.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true,environmentVariables=[{name=AWS_ACCOUNT_ID,value=$ACCOUNT_ID},{name=IMAGE_REPO_NAME,value=$REPO_NAME}]" \
    --service-role arn:aws:iam::$ACCOUNT_ID:role/blacklistCodeBuildRole \
    --logs-config "cloudWatchLogs={status=ENABLED,groupName=/aws/codebuild/floropitos-cicd}" >/dev/null
}

step_out() {
  log "Listo"
  echo "URL del microservicio:  http://$ALB_DNS"
  echo "Health:                 curl http://$ALB_DNS/health"
}

steps=${1:-"ecr net rds ssm iam logs alb image ecs codedeploy codebuild out"}
for s in $steps; do step_$s; done
