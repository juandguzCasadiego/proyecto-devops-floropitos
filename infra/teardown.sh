#!/usr/bin/env bash
# Elimina los recursos de la Entrega 3 para no seguir consumiendo creditos.
set -uo pipefail
export AWS_DEFAULT_REGION=us-east-1
aws codepipeline delete-pipeline --name blacklist-pipeline
aws deploy delete-deployment-group --application-name blacklist-cd --deployment-group-name blacklist-dg
aws deploy delete-application --application-name blacklist-cd
aws ecs update-service --cluster blacklist-cluster --service blacklist-service --desired-count 0 >/dev/null
aws ecs delete-service --cluster blacklist-cluster --service blacklist-service --force >/dev/null
sleep 30
aws ecs delete-cluster --cluster blacklist-cluster >/dev/null
ALB=$(aws elbv2 describe-load-balancers --names blacklist-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 delete-load-balancer --load-balancer-arn $ALB; sleep 20
for c in blue green; do aws elbv2 delete-target-group --target-group-arn $(aws elbv2 describe-target-groups --names blacklist-tg-$c --query 'TargetGroups[0].TargetGroupArn' --output text); done
aws rds delete-db-instance --db-instance-identifier blacklist-db --skip-final-snapshot --delete-automated-backups >/dev/null
aws ecr delete-repository --repository-name blacklist-app --force >/dev/null
aws codebuild delete-project --name floropitos-cicd
echo "Recursos eliminados (los grupos de seguridad y el subnet group de RDS se pueden borrar cuando RDS termine)."
