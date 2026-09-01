with 

recommendations as (

    select *
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_monthly_recommendations

),

clinic_info as (

    select distinct
        ship_to_account_number,
        ship_to_account_name,
        ship_to_sales_territory
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_recommendation_setup

),

recommendations_with_names as (

    select
        r.*,
        c.ship_to_sales_territory
    from recommendations r
    left join clinic_info c
        on r.ship_to_account_number = c.ship_to_account_number

),

with_top_flag as (

    select
        *,
        
        case
            when clinic_disease_rank = 1 then true
            else false
        end as top_dc_in_clinic_flag

    from recommendations_with_names

),

with_reason as (

    select
        *,
        
        case
            when action ilike 'EDUCATION%' then 'Strategic education priority - High opportunity + Eligible for training'
            when action ilike '%follow%'   then 'Tactical visit priority - Urgency-based allocation'
            else 'Standard contact'
        end as reason

    from with_top_flag

),

with_6m_sales as (

    select
        *,
        disease_expected_12m_sales  / 2.0 as expected_6m_sales,
        disease_expected_12m_volume / 2.0 as expected_6m_volume

    from with_reason

),

final as (

    select
        ship_to_account_number,
        ship_to_account_name,
        disease_category,
        species,
        scenario_disease_category,
        top_dc_in_clinic_flag,
        ship_to_customer_tier,
        clinic_disease_rank,
        territory_disease_rank,
        ship_to_sales_territory_description,
        ship_to_sales_territory,
        action,
        reason,
        expected_6m_sales,
        expected_6m_volume,
        disease_expected_12m_sales,
        disease_expected_12m_volume,
        disease_opportunity,
        disease_opportunity_volume,
        DATE_TRUNC('month', CURRENT_DATE()) as scheduled_month,
        
        tier_group,
        cluster,
        clinic_total_opportunity,
        clinic_total_opportunity_volume,
        has_sample,
        dc_share_pct,
        dc_edu_flag,
        dc_sample_flag,
        dc_opportunity_classification

    from with_6m_sales

)

select
    ship_to_account_number              as "CLINIC ID",
    ship_to_account_name                as "CLINIC NAME",
    disease_category                    as "DISEASE CATEGORY",
    species                             as "SPECIES",
    scenario_disease_category           as "SCENARIO - CLINIC DISEASE CATEGORY",
    top_dc_in_clinic_flag               as "TOP DISEASE CATEGORY IN CLINIC FLAG",
    ship_to_customer_tier               as "CLINIC TIER",
    tier_group                          as "TIER GROUP",
    cluster                             as "CLUSTER",
    clinic_disease_rank                 as "OPPORTUNITY RANKING WITHIN CLINIC",
    territory_disease_rank              as "OPPORTUNITY RANKING WITHIN TM",
    ship_to_sales_territory             as " CLINIC TERRITORY",
    ship_to_sales_territory_description as "CLINIC SALES REP OR TM",
    action                              as "ACTION RECOMMENDATION",
    has_sample                          as "HAS SAMPLE",
    reason                              as "REASON",
    dc_share_pct                        as disease_category_share_pct,
    dc_edu_flag                         as disease_category_education_flag,
    dc_sample_flag                      as disease_category_sample_flag,
    dc_opportunity_classification       as disease_category_opportunity_classification,
    expected_6m_sales                   as "EXPECTED SALES NEXT 6 MONTHS",
    expected_6m_volume                  as "EXPECTED VOLUME NEXT 6 MONTHS",
    disease_expected_12m_sales          as "EXPECTED SALES NEXT 12 MONTHS",
    disease_expected_12m_volume         as "EXPECTED VOLUME NEXT 12 MONTHS",
    disease_opportunity                 as "MONTHLY OPPORTUNITY",
    disease_opportunity_volume          as "MONTHLY OPPORTUNITY VOLUME",
    clinic_total_opportunity            as "CLINIC TOTAL MONTHLY OPPORTUNITY",
    clinic_total_opportunity_volume     as "CLINIC TOTAL MONTHLY OPPORTUNITY VOLUME",
    scheduled_month                     as "SCHEDULED MONTH"

from final
order by
    "CLINIC ID",
    "OPPORTUNITY RANKING WITHIN CLINIC",
    "SPECIES"