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

- `bash` 4+
- `make`
- `jq`
- `terraform`
- `terraformer`
- `aws` (AWS CLI v2)

Observacao de compatibilidade:
- Em Linux moderno funciona direto.
- Em macOS, o Bash padrao pode ser 3.x; nesse caso, instale Bash 4+ (ex.: via Homebrew) e execute com ele.

## Estrutura

- `config/import-config.json`: define modulos, recursos e parametros de import.
- `config/backend-config.example.json`: exemplo de backend remoto.
- `config/terraform-modules-config.example.json`: configura a integracao com `../terraform-modules`.
- `config/import-map.example.json`: modelo para mapear `address` e `id` de `terraform import`.
- `scripts/create-remote-backend.sh`: cria bucket S3 + tabela DynamoDB e opcionalmente gera `backend-config.json`.
- `scripts/import-module.sh`: importa um modulo.
- `scripts/import-all.sh`: importa todos os modulos habilitados.
- `scripts/run-terraform-modules.sh`: executa `plan`, `apply` ou `import` direto nos stacks `live/<client>/<env>/<stack>` do `terraform-modules`.
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

## Integracao com terraform-modules

Se voce quer que o `terraform-import` execute exatamente o codigo do repositorio `terraform-modules`, use este fluxo.

1. Crie o arquivo de configuracao:

```bash
cp config/terraform-modules-config.example.json config/terraform-modules-config.json
```

2. Ajuste no arquivo:
- `terraformModulesPath` (exemplo: `../terraform-modules`)
- `client` (exemplo: `client-a`)
- `environment` (exemplo: `dev`)

3. Rode plan nos stacks do `terraform-modules`:

```bash
make modules-plan
```

4. Para aplicar:

```bash
make modules-apply AUTO_APPROVE=1
```

5. Para importar recursos existentes para os enderecos do codigo de modulo:

```bash
cp config/import-map.example.json config/import-map.json
make modules-import IMPORT_MAP=config/import-map.json
```

Comandos uteis:

```bash
make modules-plan ONLY=vpc,rds,s3
make modules-dry-run ONLY=eks,ecs
make modules-apply ONLY=vpc,iam-role,iam-workload-roles SYNC_BACKEND=1 AUTO_APPROVE=1
make check-unix
```

## Observacoes

- O arquivo `config/import-config.json` usa nomes de recursos do `terraformer`. Ajuste conforme a versao que voce utiliza.
- Para `iam-role` e `iam-workload-roles`, voce pode restringir com filtros no campo `filters`.
- Os states sao gravados por modulo/pasta usando `stateKeyPrefix`:
  - Exemplo: `terraform-import/vpc/.../terraform.tfstate`
- Na integracao com `terraform-modules`, os modulos `iam-role` e `iam-workload-roles` sao mapeados para o stack `iam`.
- Se `SYNC_BACKEND=1`, o script atualiza `backend.hcl` em cada stack do `terraform-modules` usando `config/backend-config.json`.
