# AWS CI/CD Steps (CMD-Based, Final)

## 1. What I installed and used
1. AWS CLI v2
2. Docker Desktop (running)
3. Git
4. Java 17 (JDK)
5. Maven 3.9+
6. AWS account with permissions for: IAM, ECR, ECS, CodeBuild, CodePipeline, S3, CloudWatch Logs, EC2 (describe)

## 2. Project and GitHub used
1. Local project folder:
   - `C:\Users\Ahmad\Downloads\demo\demo`
2. GitHub owner used:
   - `keerthi-mirajkar-ds`
3. Repository expected by scripts (default):
   - `inventory-demo`

## 3. Local verification I ran
```cmd
cd C:\Users\Ahmad\Downloads\demo\demo
mvn clean package -DskipTests
docker build -t test-app .
docker run -p 8080:8080 test-app
```

## 4. AWS connection setup (required before pipeline)
1. Check if a CodeStar connection exists:
```cmd
aws codestar-connections list-connections --region us-east-2
```
2. If empty, create one:
```cmd
aws codestar-connections create-connection --provider-type GitHub --connection-name github-inventory --region us-east-2
```
3. Complete GitHub authorization in console:
   - `https://us-east-2.console.aws.amazon.com/codesuite/settings/connections?region=us-east-2`
4. Copy the real connection ARN (status must be `AVAILABLE`).

## 5. One-command infrastructure + pipeline setup (CMD)
I used the CMD script:
- `setup-aws-cicd.cmd`

Run:
```cmd
cd C:\Users\Ahmad\Downloads\demo\demo
setup-aws-cicd.cmd arn:aws:codestar-connections:us-east-2:102700622735:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Optional (create/update resources without starting pipeline):
```cmd
setup-aws-cicd.cmd arn:aws:codestar-connections:us-east-2:102700622735:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx nostart
```

## 6. What the setup script creates/updates
1. ECR repository: `inventory-app`
2. IAM roles and inline policies for CodeBuild and CodePipeline
3. ECS cluster/service/task definition (Fargate)
4. CloudWatch log group for ECS tasks
5. CodeBuild project using `buildspec.yml` with Docker privileged mode
6. S3 artifact bucket for pipeline artifacts
7. CodePipeline stages: Source (GitHub connection) -> Build (CodeBuild) -> Deploy (ECS)

## 7. Project changes I kept
1. `pom.xml` uses stable Spring Boot dependencies (`3.3.5`)
2. `buildspec.yml` tags/pushes ECR images and writes `imagedefinitions.json`
3. `Controller.java` includes:
   - `GET /`
   - `GET /api/health`
   - `GET /api/inventory`
4. `setup-aws-cicd.cmd` default GitHub owner is now:
   - `keerthi-mirajkar-ds`

## 8. Useful monitoring commands
```cmd
aws codepipeline get-pipeline-state --name inventory-pipeline --region us-east-2
aws ecs describe-services --cluster inventory-cluster --services inventory-service --region us-east-2
aws codebuild list-builds-for-project --project-name inventory-codebuild --region us-east-2
```

## 9. If repository name is different
If the repo under `keerthi-mirajkar-ds` is not `inventory-demo`, edit one line in:
- `setup-aws-cicd.cmd`: `set "GITHUB_REPO=..."`
