with 

scenario_data as (

    select *
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

-- GET CLUSTER ASSIGNMENTS
cluster_assignments as (

    select
        ship_to_account_number,
        ship_to_customer_tier,
        tier_group,
        cluster,
        cluster_volume,
        sales_segment_in_cluster,
        volume_segment_in_cluster

    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_next_step

),

-- JOIN SCENARIO DATA WITH CLUSTERS
with_clusters as (

    select
        sd.*,
        ca.tier_group,
        ca.cluster,
        ca.cluster_volume,
        ca.sales_segment_in_cluster,
        ca.volume_segment_in_cluster,
        
        month(sd.invoice_month) as month_number

    from scenario_data sd
    left join cluster_assignments ca
        on sd.ship_to_account_number = ca.ship_to_account_number

),

-- FILTER TO ACTIVE CLINICS ONLY (FOR PATTERN LEARNING)
active_only as (

    select *
    from with_clusters
    where scenario_disease_category in ('Active', 'New', 'Recover')
        and tier_group is not null
        and cluster is not null

),

-- CALCULATE TOTAL ANNUAL SALES PER CLUSTER × DISEASE
cluster_annual_sales as (

    select
        tier_group,
        cluster,
        disease_category,
        species,
        
        sum(sales_usd_disease_category)    as total_annual_sales,
        sum(sales_volume_disease_category) as total_annual_volume

    from active_only
    group by tier_group, cluster, disease_category, species

),

-- CALCULATE MONTHLY SALES PER CLUSTER × DISEASE
cluster_monthly_sales as (

    select
        tier_group,
        cluster,
        disease_category,
        species,
        month_number,
        
        sum(sales_usd_disease_category)    as total_monthly_sales,
        sum(sales_volume_disease_category) as total_monthly_volume

    from active_only
    group by tier_group, cluster, disease_category, species, month_number

),

-- CALCULATE DISTRIBUTION (% OF ANNUAL IN EACH MONTH)
cluster_distribution as (

    select
        cms.tier_group,
        cms.cluster,
        cms.disease_category,
        cms.species,
        cms.month_number,
        
        cms.total_monthly_sales,
        cas.total_annual_sales,
        cms.total_monthly_volume,
        cas.total_annual_volume,
        
        cms.total_monthly_sales  / nullif(cas.total_annual_sales, 0)  as cluster_sales_distribution_monthly,
        cms.total_monthly_volume / nullif(cas.total_annual_volume, 0) as cluster_volume_distribution_monthly

    from cluster_monthly_sales cms
    join cluster_annual_sales cas
        on  cms.tier_group       = cas.tier_group
        and cms.cluster          = cas.cluster
        and cms.disease_category = cas.disease_category
        and cms.species          = cas.species

)

select
    tier_group,
    cluster,
    disease_category,
    species,
    month_number,
    cluster_sales_distribution_monthly,
    cluster_volume_distribution_monthly

from cluster_distribution
order by tier_group, cluster, disease_category, species, month_number