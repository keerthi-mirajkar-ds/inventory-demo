@echo off
setlocal EnableExtensions DisableDelayedExpansion

REM ==========================================================
REM AWS CI/CD setup script (CMD-only)
REM Usage:
REM   setup-aws-cicd.cmd <connection-arn> [nostart]
REM Example:
REM   setup-aws-cicd.cmd arn:aws:codestar-connections:us-east-2:123456789012:connection/abc-def
REM   setup-aws-cicd.cmd arn:aws:codestar-connections:us-east-2:123456789012:connection/abc-def nostart
REM ==========================================================

set "REGION=us-east-2"
set "GITHUB_OWNER=keerthi-mirajkar-ds"
set "GITHUB_REPO=inventory-demo"
set "GITHUB_BRANCH=main"
set "ECR_REPO_NAME=inventory-app"
set "CONTAINER_NAME=inventory-task"
set "CLUSTER_NAME=inventory-cluster"
set "SERVICE_NAME=inventory-task-service-fgivxhd5"
set "TASK_FAMILY=inventory-task"
set "CODEBUILD_PROJECT_NAME=inventory-codebuild"
set "PIPELINE_NAME=inventory-task"
set "START_PIPELINE=true"

if "%~1"=="" (
  echo ERROR: Missing connection ARN.
  echo Usage: %~nx0 ^<connection-arn^> [nostart]
  exit /b 1
)
set "CONNECTION_ARN=%~1"
if /I "%~2"=="nostart" set "START_PIPELINE=false"

echo.%CONNECTION_ARN% | find "..." >nul && (
  echo ERROR: Connection ARN contains placeholder "..."
  exit /b 1
)
echo.%CONNECTION_ARN% | find "<" >nul && (
  echo ERROR: Connection ARN contains placeholder characters.
  exit /b 1
)
echo.%CONNECTION_ARN% | find ">" >nul && (
  echo ERROR: Connection ARN contains placeholder characters.
  exit /b 1
)

where aws >nul 2>&1
if errorlevel 1 (
  echo ERROR: aws CLI is not installed or not in PATH.
  exit /b 1
)

echo [INFO] Checking AWS CLI availability
for /f "usebackq delims=" %%i in (`aws --version 2^>nul`) do set "AWS_VERSION=%%i"
echo %AWS_VERSION%

echo [INFO] Validating AWS identity
for /f "usebackq delims=" %%i in (`aws sts get-caller-identity --query Account --output text 2^>nul`) do set "ACCOUNT_ID=%%i"
if not defined ACCOUNT_ID (
  echo ERROR: Could not get AWS account ID. Check credentials with: aws configure
  exit /b 1
)
echo AWS Account: %ACCOUNT_ID%

echo [INFO] Using provided CodeStar connection ARN

set "ECR_URI=%ACCOUNT_ID%.dkr.ecr.%REGION%.amazonaws.com/%ECR_REPO_NAME%"
set "TMP_DIR=%TEMP%\aws-cicd-%RANDOM%%RANDOM%"
mkdir "%TMP_DIR%" >nul 2>&1
if errorlevel 1 (
  echo ERROR: Could not create temp directory.
  exit /b 1
)

set "TRUST_ECS=%TMP_DIR%\trust-ecs-task-execution.json"
set "TRUST_CODEBUILD=%TMP_DIR%\trust-codebuild.json"
set "TRUST_CODEPIPELINE=%TMP_DIR%\trust-codepipeline.json"
set "POLICY_CODEBUILD=%TMP_DIR%\policy-codebuild.json"
set "POLICY_CODEPIPELINE=%TMP_DIR%\policy-codepipeline.json"
set "TASKDEF_JSON=%TMP_DIR%\taskdef.json"
set "PIPELINE_JSON=%TMP_DIR%\pipeline.json"

> "%TRUST_ECS%" (
  echo {
  echo   "Version": "2012-10-17",
  echo   "Statement": [
  echo     {
  echo       "Effect": "Allow",
  echo       "Principal": { "Service": "ecs-tasks.amazonaws.com" },
  echo       "Action": "sts:AssumeRole"
  echo     }
  echo   ]
  echo }
)

> "%TRUST_CODEBUILD%" (
  echo {
  echo   "Version": "2012-10-17",
  echo   "Statement": [
  echo     {
  echo       "Effect": "Allow",
  echo       "Principal": { "Service": "codebuild.amazonaws.com" },
  echo       "Action": "sts:AssumeRole"
  echo     }
  echo   ]
  echo }
)

> "%TRUST_CODEPIPELINE%" (
  echo {
  echo   "Version": "2012-10-17",
  echo   "Statement": [
  echo     {
  echo       "Effect": "Allow",
  echo       "Principal": { "Service": "codepipeline.amazonaws.com" },
  echo       "Action": "sts:AssumeRole"
  echo     }
  echo   ]
  echo }
)

set "CODEBUILD_ROLE_NAME=%CODEBUILD_PROJECT_NAME%-role"
set "CODEPIPELINE_ROLE_NAME=%PIPELINE_NAME%-role"

echo [INFO] Ensuring ECR repository
aws ecr describe-repositories --repository-names "%ECR_REPO_NAME%" --region "%REGION%" >nul 2>&1
if errorlevel 1 (
  aws ecr create-repository --repository-name "%ECR_REPO_NAME%" --image-scanning-configuration scanOnPush=true --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create ECR repository."
    goto :fail
  )
  echo Created ECR repository: %ECR_REPO_NAME%
) else (
  echo ECR repository already exists: %ECR_REPO_NAME%
)

echo [INFO] Ensuring ECS task execution role
aws iam get-role --role-name "ecsTaskExecutionRole" >nul 2>&1
if errorlevel 1 (
  aws iam create-role --role-name "ecsTaskExecutionRole" --assume-role-policy-document "file://%TRUST_ECS%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create ecsTaskExecutionRole."
    goto :fail
  )
  echo Created role: ecsTaskExecutionRole
) else (
  echo IAM role already exists: ecsTaskExecutionRole
)
aws iam attach-role-policy --role-name "ecsTaskExecutionRole" --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >nul
if errorlevel 1 (
  set "FAIL_REASON=Failed attaching AmazonECSTaskExecutionRolePolicy."
  goto :fail
)
for /f "usebackq delims=" %%i in (`aws iam get-role --role-name "ecsTaskExecutionRole" --query "Role.Arn" --output text 2^>nul`) do set "ECS_TASK_EXEC_ROLE_ARN=%%i"
if not defined ECS_TASK_EXEC_ROLE_ARN (
  set "FAIL_REASON=Could not read ecsTaskExecutionRole ARN."
  goto :fail
)

echo [INFO] Ensuring CodeBuild role
aws iam get-role --role-name "%CODEBUILD_ROLE_NAME%" >nul 2>&1
if errorlevel 1 (
  aws iam create-role --role-name "%CODEBUILD_ROLE_NAME%" --assume-role-policy-document "file://%TRUST_CODEBUILD%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create %CODEBUILD_ROLE_NAME%."
    goto :fail
  )
  echo Created role: %CODEBUILD_ROLE_NAME%
) else (
  echo IAM role already exists: %CODEBUILD_ROLE_NAME%
)

> "%POLICY_CODEBUILD%" (
  echo {
  echo   "Version": "2012-10-17",
  echo   "Statement": [
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "sts:GetCallerIdentity"],
  echo       "Resource": "*"
  echo     },
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket"],
  echo       "Resource": "*"
  echo     },
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": [
  echo         "ecr:GetAuthorizationToken",
  echo         "ecr:BatchCheckLayerAvailability",
  echo         "ecr:GetDownloadUrlForLayer",
  echo         "ecr:BatchGetImage",
  echo         "ecr:InitiateLayerUpload",
  echo         "ecr:UploadLayerPart",
  echo         "ecr:CompleteLayerUpload",
  echo         "ecr:PutImage"
  echo       ],
  echo       "Resource": "*"
  echo     }
  echo   ]
  echo }
)
aws iam put-role-policy --role-name "%CODEBUILD_ROLE_NAME%" --policy-name "%CODEBUILD_PROJECT_NAME%-inline" --policy-document "file://%POLICY_CODEBUILD%" >nul
if errorlevel 1 (
  set "FAIL_REASON=Failed to put inline policy on %CODEBUILD_ROLE_NAME%."
  goto :fail
)
for /f "usebackq delims=" %%i in (`aws iam get-role --role-name "%CODEBUILD_ROLE_NAME%" --query "Role.Arn" --output text 2^>nul`) do set "CODEBUILD_ROLE_ARN=%%i"
if not defined CODEBUILD_ROLE_ARN (
  set "FAIL_REASON=Could not read %CODEBUILD_ROLE_NAME% ARN."
  goto :fail
)

echo [INFO] Ensuring CodePipeline role
aws iam get-role --role-name "%CODEPIPELINE_ROLE_NAME%" >nul 2>&1
if errorlevel 1 (
  aws iam create-role --role-name "%CODEPIPELINE_ROLE_NAME%" --assume-role-policy-document "file://%TRUST_CODEPIPELINE%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create %CODEPIPELINE_ROLE_NAME%."
    goto :fail
  )
  echo Created role: %CODEPIPELINE_ROLE_NAME%
) else (
  echo IAM role already exists: %CODEPIPELINE_ROLE_NAME%
)

> "%POLICY_CODEPIPELINE%" (
  echo {
  echo   "Version": "2012-10-17",
  echo   "Statement": [
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket"],
  echo       "Resource": "*"
  echo     },
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": ["codebuild:StartBuild", "codebuild:BatchGetBuilds"],
  echo       "Resource": "*"
  echo     },
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": ["ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:UpdateService"],
  echo       "Resource": "*"
  echo     },
  echo     {
  echo       "Effect": "Allow",
  echo       "Action": ["iam:PassRole", "codestar-connections:UseConnection"],
  echo       "Resource": "*"
  echo     }
  echo   ]
  echo }
)
aws iam put-role-policy --role-name "%CODEPIPELINE_ROLE_NAME%" --policy-name "%PIPELINE_NAME%-inline" --policy-document "file://%POLICY_CODEPIPELINE%" >nul
if errorlevel 1 (
  set "FAIL_REASON=Failed to put inline policy on %CODEPIPELINE_ROLE_NAME%."
  goto :fail
)
for /f "usebackq delims=" %%i in (`aws iam get-role --role-name "%CODEPIPELINE_ROLE_NAME%" --query "Role.Arn" --output text 2^>nul`) do set "CODEPIPELINE_ROLE_ARN=%%i"
if not defined CODEPIPELINE_ROLE_ARN (
  set "FAIL_REASON=Could not read %CODEPIPELINE_ROLE_NAME% ARN."
  goto :fail
)

echo [INFO] Waiting for IAM role propagation
timeout /t 12 /nobreak >nul

echo [INFO] Ensuring ECS cluster
for /f "usebackq delims=" %%i in (`aws ecs describe-clusters --clusters "%CLUSTER_NAME%" --query "clusters[0].status" --output text --region "%REGION%" 2^>nul`) do set "CLUSTER_STATUS=%%i"
if /I "%CLUSTER_STATUS%"=="None" (
  aws ecs create-cluster --cluster-name "%CLUSTER_NAME%" --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create ECS cluster."
    goto :fail
  )
  echo Created ECS cluster: %CLUSTER_NAME%
) else (
  echo ECS cluster already exists: %CLUSTER_NAME%
)

set "SERVICE_STATUS="
set "NETWORK_SERVICE_NAME=%SERVICE_NAME%"
for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%SERVICE_NAME%" --query "services[0].status" --output text --region "%REGION%" 2^>nul`) do set "SERVICE_STATUS=%%i"
if not defined SERVICE_STATUS set "SERVICE_STATUS=None"
if /I "%SERVICE_STATUS%"=="None" (
  set "AUTO_SERVICE_ARN="
  for /f "usebackq delims=" %%i in (`aws ecs list-services --cluster "%CLUSTER_NAME%" --query "serviceArns[0]" --output text --region "%REGION%" 2^>nul`) do set "AUTO_SERVICE_ARN=%%i"
  if defined AUTO_SERVICE_ARN if /I not "%AUTO_SERVICE_ARN%"=="None" (
    for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%AUTO_SERVICE_ARN%" --query "services[0].serviceName" --output text --region "%REGION%" 2^>nul`) do set "NETWORK_SERVICE_NAME=%%i"
    for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%AUTO_SERVICE_ARN%" --query "services[0].status" --output text --region "%REGION%" 2^>nul`) do set "SERVICE_STATUS=%%i"
    if defined NETWORK_SERVICE_NAME if /I not "%NETWORK_SERVICE_NAME%"=="None" set "SERVICE_NAME=%NETWORK_SERVICE_NAME%"
  )
)

if /I not "%SERVICE_STATUS%"=="None" (
  echo [INFO] Using network configuration from existing ECS service: %SERVICE_NAME%
  set "SUBNETS_CSV="
  set "SGS_CSV="
  set "ASSIGN_PUBLIC_IP="
  for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%SERVICE_NAME%" --query "join(',',services[0].networkConfiguration.awsvpcConfiguration.subnets)" --output text --region "%REGION%" 2^>nul`) do set "SUBNETS_CSV=%%i"
  for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%SERVICE_NAME%" --query "join(',',services[0].networkConfiguration.awsvpcConfiguration.securityGroups)" --output text --region "%REGION%" 2^>nul`) do set "SGS_CSV=%%i"
  for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%SERVICE_NAME%" --query "services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp" --output text --region "%REGION%" 2^>nul`) do set "ASSIGN_PUBLIC_IP=%%i"
  if not defined SUBNETS_CSV (
    set "FAIL_REASON=Could not read subnets from existing ECS service %SERVICE_NAME%."
    goto :fail
  )
  if /I "%SUBNETS_CSV%"=="None" (
    set "FAIL_REASON=Could not read subnets from existing ECS service %SERVICE_NAME%."
    goto :fail
  )
  if not defined SGS_CSV (
    set "FAIL_REASON=Could not read security groups from existing ECS service %SERVICE_NAME%."
    goto :fail
  )
  if /I "%SGS_CSV%"=="None" (
    set "FAIL_REASON=Could not read security groups from existing ECS service %SERVICE_NAME%."
    goto :fail
  )
  if not defined ASSIGN_PUBLIC_IP set "ASSIGN_PUBLIC_IP=ENABLED"
  if /I "%ASSIGN_PUBLIC_IP%"=="None" set "ASSIGN_PUBLIC_IP=ENABLED"
) else (
  echo [INFO] No ECS service networking found, falling back to EC2 VPC discovery
  set "DEFAULT_VPC_ID="
  for /f "usebackq delims=" %%i in (`aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text --region "%REGION%" 2^>nul`) do set "DEFAULT_VPC_ID=%%i"
  if not defined DEFAULT_VPC_ID (
    for /f "usebackq delims=" %%i in (`aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text --region "%REGION%" 2^>nul`) do set "DEFAULT_VPC_ID=%%i"
  )
  if not defined DEFAULT_VPC_ID (
    set "FAIL_REASON=No VPC found in %REGION%. Create a VPC and subnets first."
    goto :fail
  )
  if /I "%DEFAULT_VPC_ID%"=="None" (
    set "FAIL_REASON=No VPC found in %REGION%. Create a VPC and subnets first."
    goto :fail
  )

  for /f "usebackq delims=" %%i in (`aws ec2 describe-subnets --filters Name=vpc-id,Values=%DEFAULT_VPC_ID% --query "join(',',Subnets[].SubnetId)" --output text --region "%REGION%" 2^>nul`) do set "SUBNETS_CSV=%%i"
  if not defined SUBNETS_CSV (
    set "FAIL_REASON=No subnets found in VPC %DEFAULT_VPC_ID%."
    goto :fail
  )
  if /I "%SUBNETS_CSV%"=="None" (
    set "FAIL_REASON=No subnets found in VPC %DEFAULT_VPC_ID%."
    goto :fail
  )

  for /f "usebackq delims=" %%i in (`aws ec2 describe-security-groups --filters Name=vpc-id,Values=%DEFAULT_VPC_ID% Name=group-name,Values=default --query "SecurityGroups[0].GroupId" --output text --region "%REGION%" 2^>nul`) do set "DEFAULT_SG_ID=%%i"
  if not defined DEFAULT_SG_ID (
    for /f "usebackq delims=" %%i in (`aws ec2 describe-security-groups --filters Name=vpc-id,Values=%DEFAULT_VPC_ID% --query "SecurityGroups[0].GroupId" --output text --region "%REGION%" 2^>nul`) do set "DEFAULT_SG_ID=%%i"
  )
  if not defined DEFAULT_SG_ID (
    set "FAIL_REASON=No security group found in VPC %DEFAULT_VPC_ID%."
    goto :fail
  )
  if /I "%DEFAULT_SG_ID%"=="None" (
    set "FAIL_REASON=No security group found in VPC %DEFAULT_VPC_ID%."
    goto :fail
  )
  set "SGS_CSV=%DEFAULT_SG_ID%"
  set "ASSIGN_PUBLIC_IP=ENABLED"
)

echo [INFO] Ensuring CloudWatch log group
for /f "usebackq delims=" %%i in (`aws logs describe-log-groups --log-group-name-prefix "/ecs/%TASK_FAMILY%" --query "logGroups[?logGroupName=='/ecs/%TASK_FAMILY%'] | [0].logGroupName" --output text --region "%REGION%" 2^>nul`) do set "CW_LOG_GROUP=%%i"
if /I "%CW_LOG_GROUP%"=="None" (
  aws logs create-log-group --log-group-name "/ecs/%TASK_FAMILY%" --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create log group /ecs/%TASK_FAMILY%."
    goto :fail
  )
  echo Created log group: /ecs/%TASK_FAMILY%
) else (
  echo CloudWatch log group exists: /ecs/%TASK_FAMILY%
)

echo [INFO] Registering ECS task definition
> "%TASKDEF_JSON%" (
  echo {
  echo   "family": "%TASK_FAMILY%",
  echo   "networkMode": "awsvpc",
  echo   "requiresCompatibilities": ["FARGATE"],
  echo   "cpu": "256",
  echo   "memory": "512",
  echo   "executionRoleArn": "%ECS_TASK_EXEC_ROLE_ARN%",
  echo   "containerDefinitions": [
  echo     {
  echo       "name": "%CONTAINER_NAME%",
  echo       "image": "%ECR_URI%:latest",
  echo       "essential": true,
  echo       "portMappings": [
  echo         {
  echo           "containerPort": 8080,
  echo           "hostPort": 8080,
  echo           "protocol": "tcp"
  echo         }
  echo       ],
  echo       "logConfiguration": {
  echo         "logDriver": "awslogs",
  echo         "options": {
  echo           "awslogs-group": "/ecs/%TASK_FAMILY%",
  echo           "awslogs-region": "%REGION%",
  echo           "awslogs-stream-prefix": "ecs"
  echo         }
  echo       }
  echo     }
  echo   ]
  echo }
)
for /f "usebackq delims=" %%i in (`aws ecs register-task-definition --cli-input-json "file://%TASKDEF_JSON%" --query "taskDefinition.taskDefinitionArn" --output text --region "%REGION%" 2^>nul`) do set "TASKDEF_ARN=%%i"
if not defined TASKDEF_ARN (
  set "FAIL_REASON=Failed to register task definition."
  goto :fail
)

echo [INFO] Ensuring ECS service
for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%SERVICE_NAME%" --query "services[0].status" --output text --region "%REGION%" 2^>nul`) do set "SERVICE_STATUS=%%i"
set "NETWORK_CFG=awsvpcConfiguration={subnets=[%SUBNETS_CSV%],securityGroups=[%SGS_CSV%],assignPublicIp=%ASSIGN_PUBLIC_IP%}"
if /I "%SERVICE_STATUS%"=="None" (
  aws ecs create-service --cluster "%CLUSTER_NAME%" --service-name "%SERVICE_NAME%" --task-definition "%TASKDEF_ARN%" --desired-count 1 --launch-type FARGATE --platform-version LATEST --network-configuration "%NETWORK_CFG%" --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create ECS service."
    goto :fail
  )
  echo Created ECS service: %SERVICE_NAME%
) else (
  aws ecs update-service --cluster "%CLUSTER_NAME%" --service "%SERVICE_NAME%" --task-definition "%TASKDEF_ARN%" --desired-count 1 --force-new-deployment --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to update ECS service."
    goto :fail
  )
  echo Updated ECS service: %SERVICE_NAME%
)

echo [INFO] Detecting ECS container name for deployment mapping
set "SERVICE_TASKDEF_ARN="
for /f "usebackq delims=" %%i in (`aws ecs describe-services --cluster "%CLUSTER_NAME%" --services "%SERVICE_NAME%" --query "services[0].taskDefinition" --output text --region "%REGION%" 2^>nul`) do set "SERVICE_TASKDEF_ARN=%%i"
if not defined SERVICE_TASKDEF_ARN (
  set "FAIL_REASON=Could not read task definition ARN from ECS service %SERVICE_NAME%."
  goto :fail
)
if /I "%SERVICE_TASKDEF_ARN%"=="None" (
  set "FAIL_REASON=Could not read task definition ARN from ECS service %SERVICE_NAME%."
  goto :fail
)

set "DETECTED_CONTAINER_NAME="
for /f "usebackq delims=" %%i in (`aws ecs describe-task-definition --task-definition "%SERVICE_TASKDEF_ARN%" --query "taskDefinition.containerDefinitions[0].name" --output text --region "%REGION%" 2^>nul`) do set "DETECTED_CONTAINER_NAME=%%i"
if not defined DETECTED_CONTAINER_NAME (
  set "FAIL_REASON=Could not detect container name from task definition %SERVICE_TASKDEF_ARN%."
  goto :fail
)
if /I "%DETECTED_CONTAINER_NAME%"=="None" (
  set "FAIL_REASON=Could not detect container name from task definition %SERVICE_TASKDEF_ARN%."
  goto :fail
)
set "CONTAINER_NAME=%DETECTED_CONTAINER_NAME%"
echo Using ECS container name: %CONTAINER_NAME%

echo [INFO] Ensuring CodeBuild project
for /f "usebackq delims=" %%i in (`aws codebuild batch-get-projects --names "%CODEBUILD_PROJECT_NAME%" --query "projects[0].name" --output text --region "%REGION%" 2^>nul`) do set "CODEBUILD_EXISTS=%%i"
set "CB_SOURCE=type=CODEPIPELINE,buildspec=buildspec.yml"
set "CB_ARTIFACTS=type=CODEPIPELINE"
set "CB_ENV=type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true,environmentVariables=[{name=AWS_DEFAULT_REGION,value=%REGION%,type=PLAINTEXT},{name=IMAGE_REPO_NAME,value=%ECR_REPO_NAME%,type=PLAINTEXT},{name=CONTAINER_NAME,value=%CONTAINER_NAME%,type=PLAINTEXT}]"
if /I "%CODEBUILD_EXISTS%"=="None" (
  aws codebuild create-project --name "%CODEBUILD_PROJECT_NAME%" --description "Build Docker image and push to ECR for ECS deploy" --service-role "%CODEBUILD_ROLE_ARN%" --source "%CB_SOURCE%" --artifacts "%CB_ARTIFACTS%" --environment "%CB_ENV%" --timeout-in-minutes 30 --queued-timeout-in-minutes 60 --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create CodeBuild project."
    goto :fail
  )
  echo Created CodeBuild project: %CODEBUILD_PROJECT_NAME%
) else (
  aws codebuild update-project --name "%CODEBUILD_PROJECT_NAME%" --description "Build Docker image and push to ECR for ECS deploy" --service-role "%CODEBUILD_ROLE_ARN%" --source "%CB_SOURCE%" --artifacts "%CB_ARTIFACTS%" --environment "%CB_ENV%" --timeout-in-minutes 30 --queued-timeout-in-minutes 60 --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to update CodeBuild project."
    goto :fail
  )
  echo Updated CodeBuild project: %CODEBUILD_PROJECT_NAME%
)

echo [INFO] Ensuring S3 artifact bucket
set "ARTIFACT_BUCKET=%PIPELINE_NAME%-artifacts-%ACCOUNT_ID%-%REGION%"
aws s3api head-bucket --bucket "%ARTIFACT_BUCKET%" >nul 2>&1
if errorlevel 1 (
  if /I "%REGION%"=="us-east-1" (
    aws s3api create-bucket --bucket "%ARTIFACT_BUCKET%" >nul
  ) else (
    aws s3api create-bucket --bucket "%ARTIFACT_BUCKET%" --create-bucket-configuration LocationConstraint=%REGION% --region "%REGION%" >nul
  )
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create artifact bucket %ARTIFACT_BUCKET%."
    goto :fail
  )
  echo Created artifact bucket: %ARTIFACT_BUCKET%
) else (
  echo Artifact bucket already exists: %ARTIFACT_BUCKET%
)
aws s3api put-bucket-versioning --bucket "%ARTIFACT_BUCKET%" --versioning-configuration Status=Enabled >nul
if errorlevel 1 (
  set "FAIL_REASON=Failed to enable bucket versioning."
  goto :fail
)

echo [INFO] Ensuring CodePipeline
> "%PIPELINE_JSON%" (
  echo {
  echo   "pipeline": {
  echo     "name": "%PIPELINE_NAME%",
  echo     "roleArn": "%CODEPIPELINE_ROLE_ARN%",
  echo     "artifactStore": {
  echo       "type": "S3",
  echo       "location": "%ARTIFACT_BUCKET%"
  echo     },
  echo     "stages": [
  echo       {
  echo         "name": "Source",
  echo         "actions": [
  echo           {
  echo             "name": "Source",
  echo             "actionTypeId": {
  echo               "category": "Source",
  echo               "owner": "AWS",
  echo               "provider": "CodeStarSourceConnection",
  echo               "version": "1"
  echo             },
  echo             "runOrder": 1,
  echo             "outputArtifacts": [{ "name": "SourceOutput" }],
  echo             "configuration": {
  echo               "ConnectionArn": "%CONNECTION_ARN%",
  echo               "FullRepositoryId": "%GITHUB_OWNER%/%GITHUB_REPO%",
  echo               "BranchName": "%GITHUB_BRANCH%",
  echo               "OutputArtifactFormat": "CODE_ZIP"
  echo             }
  echo           }
  echo         ]
  echo       },
  echo       {
  echo         "name": "Build",
  echo         "actions": [
  echo           {
  echo             "name": "Build",
  echo             "actionTypeId": {
  echo               "category": "Build",
  echo               "owner": "AWS",
  echo               "provider": "CodeBuild",
  echo               "version": "1"
  echo             },
  echo             "runOrder": 1,
  echo             "inputArtifacts": [{ "name": "SourceOutput" }],
  echo             "outputArtifacts": [{ "name": "BuildOutput" }],
  echo             "configuration": {
  echo               "ProjectName": "%CODEBUILD_PROJECT_NAME%"
  echo             }
  echo           }
  echo         ]
  echo       },
  echo       {
  echo         "name": "Deploy",
  echo         "actions": [
  echo           {
  echo             "name": "DeployToECS",
  echo             "actionTypeId": {
  echo               "category": "Deploy",
  echo               "owner": "AWS",
  echo               "provider": "ECS",
  echo               "version": "1"
  echo             },
  echo             "runOrder": 1,
  echo             "inputArtifacts": [{ "name": "BuildOutput" }],
  echo             "configuration": {
  echo               "ClusterName": "%CLUSTER_NAME%",
  echo               "ServiceName": "%SERVICE_NAME%",
  echo               "FileName": "imagedefinitions.json"
  echo             }
  echo           }
  echo         ]
  echo       }
  echo     ]
  echo   }
  echo }
)

aws codepipeline get-pipeline --name "%PIPELINE_NAME%" --region "%REGION%" >nul 2>&1
if errorlevel 1 (
  aws codepipeline create-pipeline --cli-input-json "file://%PIPELINE_JSON%" --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to create CodePipeline."
    goto :fail
  )
  echo Created CodePipeline: %PIPELINE_NAME%
) else (
  aws codepipeline update-pipeline --cli-input-json "file://%PIPELINE_JSON%" --region "%REGION%" >nul
  if errorlevel 1 (
    set "FAIL_REASON=Failed to update CodePipeline."
    goto :fail
  )
  echo Updated CodePipeline: %PIPELINE_NAME%
)

if /I "%START_PIPELINE%"=="true" (
  call :start_pipeline_with_retry
)

echo.
echo Setup completed.
echo Region: %REGION%
echo Repository: %GITHUB_OWNER%/%GITHUB_REPO%
echo ECR URI: %ECR_URI%
echo Cluster/Service: %CLUSTER_NAME% / %SERVICE_NAME%
echo CodeBuild project: %CODEBUILD_PROJECT_NAME%
echo CodePipeline: %PIPELINE_NAME%
echo Artifact bucket: %ARTIFACT_BUCKET%
echo Pipeline console:
echo https://%REGION%.console.aws.amazon.com/codesuite/codepipeline/pipelines/%PIPELINE_NAME%/view?region=%REGION%
echo.
echo Useful checks:
echo aws codepipeline get-pipeline-state --name %PIPELINE_NAME% --region %REGION%
echo aws ecs describe-services --cluster %CLUSTER_NAME% --services %SERVICE_NAME% --region %REGION%

rmdir /s /q "%TMP_DIR%" >nul 2>&1
exit /b 0

:start_pipeline_with_retry
echo [INFO] Starting pipeline execution
for /L %%R in (1,1,6) do (
  aws codepipeline start-pipeline-execution --name "%PIPELINE_NAME%" --region "%REGION%" >nul 2>&1
  if not errorlevel 1 (
    echo Pipeline execution started.
    exit /b 0
  )
  timeout /t 10 /nobreak >nul
)
echo WARNING: Could not auto-start pipeline right now.
echo Run this manually after 1 minute:
echo   aws codepipeline start-pipeline-execution --name "%PIPELINE_NAME%" --region "%REGION%"
exit /b 0

:fail
echo.
echo ERROR: %FAIL_REASON%
echo Fix the issue and run again.
rmdir /s /q "%TMP_DIR%" >nul 2>&1
exit /b 1

