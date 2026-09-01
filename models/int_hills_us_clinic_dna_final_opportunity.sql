with 

forecast_opportunity as (

    select *
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_forecast_opportunity

),

action_summary as (

    select *
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_action_summary

),

with_actions as (

    select
        fo.*,
        
        a.ship_to_sales_territory_description,
        a.total_visits,
        a.total_educations,
        a.total_samples,
        a.total_tprs,
        a.last_visit,
        a.last_education,
        a.last_sample,
        a.last_tpr

    from forecast_opportunity fo
    left join action_summary a
        on fo.ship_to_account_number = a.ship_to_account_number

),

total_ly_sales as (

    select
        ship_to_account_number,
        disease_category,
        species,
        
        sum(ly_monthly_sales)  as total_ly_sales,
        sum(ly_monthly_volume) as total_ly_volume

    from forecast_opportunity
    group by ship_to_account_number, disease_category, species

),

with_total_ly as (

    select
        wa.*,
        tly.total_ly_sales,
        tly.total_ly_volume

    from with_actions wa
    left join total_ly_sales tly
        on  wa.ship_to_account_number = tly.ship_to_account_number
        and wa.disease_category       = tly.disease_category
        and wa.species                = tly.species

),

final as (

    select
        forecast_month,
        ship_to_account_number,
        ship_to_sales_territory_description,
        ship_to_customer_tier,
        tier_group,
        
        case
            when cluster like '%-%' then split_part(cluster, '-', 2)
            else cluster
        end as cluster,

        case
            when cluster_volume like '%-%' then split_part(cluster_volume, '-', 2)
            else cluster_volume
        end as cluster_volume,
        
        sales_segment_in_cluster,
        volume_segment_in_cluster,
        
        disease_category,
        species,
        
        scenario_clinic,
        scenario_disease_category,
        
        new_expected_12_months_sales,
        new_expected_12_months_volume,
        clinic_avg_monthly_sales,
        clinic_avg_monthly_volume,
        final_monthly_opportunity,
        final_monthly_opportunity_volume,
        
        ly_monthly_sales,
        ly_monthly_volume,
        total_ly_sales,
        total_ly_volume,
        
        total_visits,
        total_educations,
        total_samples,
        total_tprs,
        
        last_visit,
        last_education,
        last_sample,
        last_tpr

    from with_total_ly

)

select *
from final
order by ship_to_account_number, disease_category, species, forecast_month