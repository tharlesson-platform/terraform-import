# terraform-import

Automacao para importar infraestrutura AWS existente para Terraform, separada por modulo, com suporte a backend remoto em S3 (state) + DynamoDB (lock).

## Modulos configurados

- vpc
- acm
- alb
- elb
- eks
- rds
- ec2
- ec2-autoscaling
- ecs
- iam-role
- iam-workload-roles
- security-baseline
- s3

## Requisitos

- `bash`
- `make`
- `jq`
- `terraform`
- `terraformer`
- `aws` (AWS CLI v2)

## Estrutura

- `config/import-config.json`: define modulos, recursos e parametros de import.
- `config/backend-config.example.json`: exemplo de backend remoto.
- `scripts/create-remote-backend.sh`: cria bucket S3 + tabela DynamoDB e opcionalmente gera `backend-config.json`.
- `scripts/import-module.sh`: importa um modulo.
- `scripts/import-all.sh`: importa todos os modulos habilitados.
- `Makefile`: comandos de alto nivel.

## Fluxo recomendado

1. Ajuste os recursos por modulo em `config/import-config.json`.
2. Crie o backend remoto:

```bash
make backend-create BUCKET=my-tf-state DYNAMODB_TABLE=tf-state-locks REGION=us-east-1 PROFILE=default
```

3. Revise o arquivo gerado `config/backend-config.json`.
4. Execute dry-run para validar comandos:

```bash
make dry-run-all
```

5. Rode importacao real com backend remoto:

```bash
make import-all-with-backend
```

## Uso rapido

Importar um modulo:

```bash
make import-module MODULE=vpc
```

Importar um modulo e configurar backend:

```bash
make import-module-with-backend MODULE=vpc
```

Importar apenas alguns modulos:

```bash
make import-all-with-backend ONLY=vpc,eks,rds
```

## Observacoes

- O arquivo `config/import-config.json` usa nomes de recursos do `terraformer`. Ajuste conforme a versao que voce utiliza.
- Para `iam-role` e `iam-workload-roles`, voce pode restringir com filtros no campo `filters`.
- Os states sao gravados por modulo/pasta usando `stateKeyPrefix`:
  - Exemplo: `terraform-import/vpc/.../terraform.tfstate`
