with 

scenario_data as (

    select *
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

active_only as (

    select 
        *,
        month(invoice_month) as month_number
    from scenario_data
    where scenario_disease_category in ('Active', 'New', 'Recover')

),

clinic_annual_sales as (

    select
        ship_to_account_number,
        disease_category,
        species,
        
        sum(sales_usd_disease_category)    as total_annual_sales,
        sum(sales_volume_disease_category) as total_annual_volume

    from active_only
    group by ship_to_account_number, disease_category, species

),

clinic_monthly_sales as (

    select
        ship_to_account_number,
        disease_category,
        species,
        month_number,
        
        sum(sales_usd_disease_category)    as total_monthly_sales,
        sum(sales_volume_disease_category) as total_monthly_volume

    from active_only
    group by ship_to_account_number, disease_category, species, month_number

),

clinic_distribution as (

    select
        cms.ship_to_account_number,
        cms.disease_category,
        cms.species,
        cms.month_number,
        
        cms.total_monthly_sales,
        cas.total_annual_sales,
        cms.total_monthly_volume,
        cas.total_annual_volume,
        
        cms.total_monthly_sales  / nullif(cas.total_annual_sales,  0) as clinic_sales_distribution_monthly,
        cms.total_monthly_volume / nullif(cas.total_annual_volume, 0) as clinic_volume_distribution_monthly

    from clinic_monthly_sales cms
    join clinic_annual_sales cas
        on  cms.ship_to_account_number = cas.ship_to_account_number
        and cms.disease_category       = cas.disease_category
        and cms.species                = cas.species

)

select
    ship_to_account_number,
    disease_category,
    species,
    month_number,
    clinic_sales_distribution_monthly,
    clinic_volume_distribution_monthly

from clinic_distribution
order by ship_to_account_number, disease_category, species, month_number