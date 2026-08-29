# Sales Productivity & Rep Segmentation Analytics

## Overview
This repository documents the technical architecture and analytical patterns behind an enterprise sales productivity solution built to identify leading indicators of representative performance.

The business problem was not simply to report booked revenue. Sales leadership needed visibility into short-cycle behaviors that precede strong or weak outcomes: quoting activity, booked opportunities, revenue pacing, margin, tenure, and performance relative to goal.

All schemas, values, examples, and code in this repository are generalized or sanitized.

## Business Problem
Key challenges included:
- sparse transactional activity that created gaps in time-series analysis
- multiple time grains with different comparison requirements
- rolling metrics that were expensive or fragile when calculated entirely in the BI layer
- separate business-event and reporting-date contexts
- rep segmentation requiring tenure, goal attainment, pacing, and rolling performance
- governed access without duplicating report logic

## Solution Architecture
```text
Operational / Transactional Sources
              |
              v
       SQL Transformation Layer
              |
              +--> Daily Aggregate Fact
              +--> Weekly Aggregate Fact
              +--> Monthly Aggregate Fact
              |
              v
     Microsoft Fabric / Direct Lake
              |
              v
        Power BI Semantic Model
              |
       +------+------+
       |             |
      DAX           RLS
       |             |
       +------+------+
              |
              v
     Sales Leadership Reporting
```

## Key Engineering Patterns

### Multi-Grain Fact Design
Daily, weekly, and monthly analytical structures are materialized separately rather than forcing one transactional fact table to serve every reporting grain.

### Dense Time-Series Scaffolding
Every relevant entity-period combination is represented before window calculations so `LAG`, rolling averages, and prior-period logic compare true adjacent periods rather than merely adjacent existing rows.

### SQL Window Functions
Selected rolling and prior-period metrics are calculated upstream for reuse and easier validation.

### Explicit Date Context
Business-event date and analytical reporting date are modeled as distinct concepts.

### Performance Segmentation
Representatives are classified using multiple signals—goal attainment, rolling performance, tenure, and pacing—rather than one static threshold.

## Repository Structure
```text
sales-productivity-analytics/
|-- README.md
|-- docs/
|-- sql/
|-- dax/
|-- images/
`-- sample-data/
```

## Business Impact
- Reduced manual aggregation and spreadsheet-based analysis
- Standardized sales-performance classifications
- Improved visibility into leading indicators of rep productivity
- Shifted expensive recurring calculations from the report layer into reusable SQL structures
- Supported governed access and consistent KPI definitions

## Technology
Power BI · Microsoft Fabric · Direct Lake · T-SQL · DAX · Power Query · Row-Level Security

## My Role
Business requirements translation · analytical architecture · SQL transformation strategy · semantic modeling · DAX · KPI logic · report UX · validation · stakeholder delivery · technical documentation

## Confidentiality
This is a sanitized technical case study. It contains no employer production data, customer or employee information, connection strings, internal server/database names, proprietary schemas, or complete production stored procedures.
