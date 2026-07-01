---
name: aws-version-lifecycle
description: Scrape AWS service version lifecycle and end-of-support dates from public documentation. Use when checking EOL dates, planning upgrades, or running end-of-support analysis for RDS, Aurora, EKS, Lambda, ElastiCache, OpenSearch, MSK, or Amazon MQ.
---

# AWS Version Lifecycle

## Overview

Dynamically scrapes AWS public documentation to retrieve current version lifecycle information including standard support and extended support end dates. Works across multiple AWS services.

**CRITICAL:**
> Never use model knowledge for EOL dates, extended support timelines, or pricing. All dates MUST come from scraping the URLs below. If scraping fails, STOP and report the failure.

## Supported Engines

| API Engine Value | Service | Has EOL Dates? |
|-----------------|---------|---------------|
| `postgres` | RDS PostgreSQL | Yes |
| `aurora-postgresql` | Aurora PostgreSQL | Yes |
| `mysql` | RDS MySQL | Yes |
| `aurora-mysql` | Aurora MySQL | Yes |
| `mariadb` | RDS MariaDB | Yes |
| `redis` | ElastiCache Redis OSS | Yes |
| `memcached` | ElastiCache Memcached | No |
| `valkey` | ElastiCache Valkey | No |
| Kubernetes | EKS | Yes |
| Lambda runtimes | Lambda | Yes |
| OpenSearch/Elasticsearch | OpenSearch Service | Yes |
| Apache Kafka | MSK | Yes |
| ActiveMQ | Amazon MQ | Yes |
| RabbitMQ | Amazon MQ | Yes |

### Engines NOT Covered

`oracle-ee`, `oracle-se2`, `oracle-ee-cdb`, `oracle-se2-cdb`, `sqlserver-ee`, `sqlserver-se`, `sqlserver-ex`, `sqlserver-web`, `custom-oracle-*`, `custom-sqlserver-*`, `docdb`, `neptune`

If an inventory contains these engines, report: "Vendor-managed lifecycle - consult vendor documentation."

### Engines With No Published EOL Dates

- **valkey** (ElastiCache) - launched Oct 2024, no EOL schedule published
- **memcached** (ElastiCache) - no EOL schedule published

Report as: "Supported - no EOL dates published by AWS."

## Engine-to-URL Mapping

Aurora and RDS have SEPARATE release calendars with DIFFERENT dates. Always use the correct URL for the engine type.

### RDS PostgreSQL

- **Primary**: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- **Extended Support**: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/extended-support.html
- **Pricing**: https://aws.amazon.com/rds/pricing/

### Aurora PostgreSQL

- **Primary**: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraPostgreSQLReleaseNotes/aurorapostgresql-release-calendar.html
- **Extended Support**: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/extended-support.html
- **Pricing**: https://aws.amazon.com/rds/aurora/pricing/

### RDS MySQL

- **Primary**: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.VersionMgmt.html
- **Extended Support**: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/extended-support.html
- **Pricing**: https://aws.amazon.com/rds/pricing/

### Aurora MySQL

- **Primary**: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraMySQLReleaseNotes/AuroraMySQL.release-calendars.html
- **Extended Support**: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/extended-support.html
- **Pricing**: https://aws.amazon.com/rds/aurora/pricing/

### RDS MariaDB

- **Primary**: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MariaDB.Concepts.VersionMgmt.html
- **Extended Support**: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/extended-support.html
- **Pricing**: https://aws.amazon.com/rds/pricing/

### EKS (Kubernetes)

- **Primary**: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
- **Pricing**: https://aws.amazon.com/eks/pricing/
- **Support Timeline**: 14 months standard support + 12 months extended support

### Lambda (Runtimes)

- **Primary**: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- **Support Timeline**: 180 days notice before deprecation. No extended support.

### ElastiCache (Redis OSS)

- **Primary**: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/engine-versions.html#deprecated-engine-versions
- **Extended Support**: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/extended-support.html
- **Pricing**: https://aws.amazon.com/elasticache/pricing/
- **Note**: Scrape the "Extended Support and End of Life schedule" table for Redis OSS dates.

### ElastiCache (Memcached)

- **Primary**: https://docs.aws.amazon.com/AmazonElastiCache/latest/mem-ug/engine-versions.html#supported-engine-versions-mc
- **Note**: No EOL schedule published.

### ElastiCache (Valkey)

- **Primary**: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/engine-versions.html
- **Note**: No EOL dates published (launched Oct 2024).

### OpenSearch/Elasticsearch

- **Primary**: https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html#choosing-version
- **Pricing**: https://aws.amazon.com/opensearch-service/pricing/

### MSK (Kafka)

- **Primary**: https://docs.aws.amazon.com/msk/latest/developerguide/supported-kafka-versions.html
- **Version Support**: https://docs.aws.amazon.com/msk/latest/developerguide/version-support.html

### Amazon MQ - ActiveMQ

- **Primary**: https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/activemq-version-management.html

### Amazon MQ - RabbitMQ

- **Primary**: https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-version-management.html

## Usage

### Step 1: Fetch Version Lifecycle Data

Use `web_fetch` to scrape the engine-specific documentation URL:

```
web_fetch(url="<ENGINE_PRIMARY_URL>", mode="full")
```

### Step 2: Parse Version Information

Extract from the page:
- Version number (major.minor)
- Standard support end date
- Extended support start date (if applicable)
- Extended support end date (if applicable)
- Current status (supported, extended support, end of support)

### Step 3: Fetch Extended Support Pricing (if applicable)

For services with extended support, also scrape the pricing page:

```
web_fetch(url="<SERVICE_PRICING_URL>", mode="selective", search_terms="extended support")
```

Extract:
- Pricing unit (per vCPU-hour, per ACU-hour, per cluster-hour, etc.)
- Year 1 pricing
- Year 2 pricing (if different)
- Year 3 pricing (if different)

### Step 4: Return Structured Data

Format as markdown table:

```markdown
| Version | Standard Support End | Extended Support End | Status |
|---------|---------------------|---------------------|--------|
| 13.x    | 2026-02-28          | 2029-02-28          | Extended Support |
| 14.x    | 2027-02-28          | 2030-02-28          | Supported |
```

For extended support pricing:

```markdown
Extended Support Pricing (scraped <DATE>):
- Unit: per vCPU-hour
- Year 1: $X.XX
- Year 2: $X.XX
- Year 3: $X.XX
```

### Step 5: Record Methodology

For every scrape, record:
- **URL scraped**: the exact URL fetched
- **Scrape timestamp**: ISO 8601 date/time
- **Versions extracted**: list of version-to-date pairs found
- **Gaps**: any versions where dates could not be determined

This data MUST be included in the calling SOP's methodology output.

## Error Handling - FAIL-STOP

If scraping fails for any engine:

1. **STOP.** Do not continue with missing dates.
2. Report: "Unable to scrape EOL dates for {engine} from {URL}. HTTP status: {code}."
3. Offer options:
   - **A)** Retry scrape
   - **B)** User provides dates manually
   - **C)** Skip this engine (record as skipped in methodology)
4. **NEVER** use model knowledge, cached dates, or dates from other engines as a substitute.
5. **NEVER** guess, estimate, or infer dates from partial information.

If a date cannot be cited to a specific URL and scrape timestamp, it MUST NOT appear in any report.

## Best Practices

1. **Always fetch fresh data** - don't reuse dates from previous runs
2. **Use full mode for web_fetch** - ensures complete page content
3. **Match engine to URL** - Aurora resources MUST use Aurora URLs, RDS resources MUST use RDS URLs
4. **Validate dates** - ensure dates parse correctly and are within reasonable range (within 5 years of today)
5. **Record methodology** - every date must be traceable to a URL and scrape timestamp
6. **Scrape all needed engines upfront** - before correlating with inventory, so failures are caught early
