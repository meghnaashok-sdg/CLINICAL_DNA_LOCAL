with 

scenario_data as (

    select * from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

cluster_assignments as (

    select
        ship_to_account_number,
        tier_group,
        cluster,
        cluster_volume,
        sales_segment_in_cluster,
        volume_segment_in_cluster

    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_next_step

),

cluster_distributions as (

    select * from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_cluster_distributions

),

clinic_distributions as (

    select * from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_clinic_distributions

),

clinic_opportunity as (

    select * from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_clinic_opportunity

),

latest_month as (

    select max(invoice_month) as max_invoice_month
    from scenario_data

),

forecast_months as (

    select 
        dateadd(month, row_number() over (order by seq4()), lm.max_invoice_month) as forecast_month

    from table(generator(rowcount => 12))
    cross join latest_month lm

),

active_combos as (

    select distinct
        ship_to_account_number,
        disease_category,
        species,
        ship_to_customer_tier

    from scenario_data

),

forecast_scaffold as (

    select
        fm.forecast_month,
        ac.ship_to_account_number,
        ac.disease_category,
        ac.species,
        ac.ship_to_customer_tier,
        
        month(fm.forecast_month) as month_number

    from forecast_months fm
    cross join active_combos ac

),

with_clusters as (

    select
        fs.*,
        ca.tier_group,
        ca.cluster,
        ca.cluster_volume,
        ca.sales_segment_in_cluster,
        ca.volume_segment_in_cluster

    from forecast_scaffold fs
    left join cluster_assignments ca
        on fs.ship_to_account_number = ca.ship_to_account_number

),

current_scenarios as (

    select
        ship_to_account_number,
        disease_category,
        species,
        scenario_clinic,
        scenario_disease_category,
        row_number() over (
            partition by ship_to_account_number, disease_category, species
            order by invoice_month desc
        ) as rn

    from scenario_data

),

with_scenario as (

    select
        wc.*,
        cs.scenario_clinic,
        cs.scenario_disease_category

    from with_clusters wc
    left join current_scenarios cs
        on  wc.ship_to_account_number = cs.ship_to_account_number
        and wc.disease_category       = cs.disease_category
        and wc.species                = cs.species
        and cs.rn = 1

),      

with_opportunity as (

    select
        ws.*,
        coalesce((co.opportunity + co.clinic_avg_monthly_sales) * 12, 0)         as new_expected_12_months_sales,
        coalesce(co.opportunity * 12, 0)                                         as new_expected_12_months_opportunity,
        coalesce(co.clinic_avg_monthly_sales,  0)                                as clinic_avg_monthly_sales,
        coalesce((co.opportunity_volume + co.clinic_avg_monthly_volume) * 12, 0) as new_expected_12_months_volume,
        coalesce(co.opportunity_volume * 12, 0)                                  as new_expected_12_months_opportunity_volume,
        coalesce(co.clinic_avg_monthly_volume, 0)                                as clinic_avg_monthly_volume

    from with_scenario ws
    left join clinic_opportunity co
        on  ws.ship_to_account_number = co.clinic_id
        and ws.disease_category       = co.disease_category
        and ws.species                = co.species

),

with_cluster_dist as (

    select
        wo.*,
        coalesce(cd.cluster_sales_distribution_monthly,  0) as cluster_sales_distribution_monthly,
        coalesce(cd.cluster_volume_distribution_monthly, 0) as cluster_volume_distribution_monthly

    from with_opportunity wo
    left join cluster_distributions cd
        on  wo.tier_group       = cd.tier_group
        and wo.cluster          = cd.cluster
        and wo.disease_category = cd.disease_category
        and wo.species          = cd.species
        and wo.month_number     = cd.month_number

),

with_clinic_dist as (

    select
        wcd.*,
        coalesce(cld.clinic_sales_distribution_monthly,  0) as clinic_sales_distribution_monthly,
        coalesce(cld.clinic_volume_distribution_monthly, 0) as clinic_volume_distribution_monthly

    from with_cluster_dist wcd
    left join clinic_distributions cld
        on  wcd.ship_to_account_number = cld.ship_to_account_number
        and wcd.disease_category       = cld.disease_category
        and wcd.species                = cld.species
        and wcd.month_number           = cld.month_number

),

ly_monthly_sales as (

    select
        ship_to_account_number,
        disease_category,
        species,
        invoice_month,
        sales_usd_disease_category    as ly_monthly_sales,
        sales_volume_disease_category as ly_monthly_volume
        
    from scenario_data

),

with_ly_sales as (

    select
        wcd.*,
        coalesce(lym.ly_monthly_sales,  0) as ly_monthly_sales,
        coalesce(lym.ly_monthly_volume, 0) as ly_monthly_volume

    from with_clinic_dist wcd
    left join ly_monthly_sales lym
        on  wcd.ship_to_account_number          = lym.ship_to_account_number
        and wcd.disease_category                = lym.disease_category
        and wcd.species                         = lym.species
        and dateadd(year, 1, lym.invoice_month) = wcd.forecast_month

),

with_final_opportunity as (

    select
        *,

        case
            when scenario_disease_category in ('Lost', 'Long term lost')
                then greatest( (new_expected_12_months_sales / 12.0) - ly_monthly_sales, 0 )
            when scenario_disease_category = 'Never happened'
                then new_expected_12_months_opportunity * cluster_sales_distribution_monthly
            else new_expected_12_months_opportunity * (
                0.5 * cluster_sales_distribution_monthly +
                0.5 * clinic_sales_distribution_monthly
            )
        end as final_monthly_opportunity,

        case
            when scenario_disease_category in ('Lost', 'Long term lost')
                then greatest( (new_expected_12_months_volume / 12.0) - ly_monthly_volume, 0 )
            when scenario_disease_category = 'Never happened'
                then new_expected_12_months_opportunity_volume * cluster_volume_distribution_monthly
            else new_expected_12_months_opportunity_volume * (
                0.5 * cluster_volume_distribution_monthly +
                0.5 * clinic_volume_distribution_monthly
            )
        end as final_monthly_opportunity_volume

    from with_ly_sales

),

final as (

    select
        forecast_month,
        ship_to_account_number,
        disease_category,
        species,
        ship_to_customer_tier,
        tier_group,
        cluster,
        cluster_volume,
        sales_segment_in_cluster,
        volume_segment_in_cluster,
    
        scenario_clinic,
        scenario_disease_category,
        
        new_expected_12_months_sales,
        new_expected_12_months_volume,
        clinic_avg_monthly_sales,
        clinic_avg_monthly_volume,
        
        ly_monthly_sales,
        ly_monthly_volume,
        
        cluster_sales_distribution_monthly,
        cluster_volume_distribution_monthly,
        clinic_sales_distribution_monthly,
        clinic_volume_distribution_monthly,
        new_expected_12_months_opportunity,
        new_expected_12_months_opportunity_volume,
        
        greatest(final_monthly_opportunity, 0)        as final_monthly_opportunity,
        greatest(final_monthly_opportunity_volume, 0) as final_monthly_opportunity_volume,
        month_number

    from with_final_opportunity

)

select *
from final