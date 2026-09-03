with as_of as (

    select
        max(invoice_month) as as_of_month
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

clusters as (

    select
        ship_to_account_number as clinic_id,
        ship_to_customer_tier,
        tier_group,
        cluster,
        cluster_volume,
        sales_segment_in_cluster,
        volume_segment_in_cluster,
        next_step_cluster,
        next_step_cluster_volume,
        next_step_segment,
        next_step_segment_volume,

    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_next_step

),

sales_base as (

    select
        ship_to_account_number as clinic_id,
        disease_category,
        species,
        invoice_month,
        sales_usd_disease_category,
        sales_volume_disease_category,
        scenario_disease_category

    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

rolling_12m as (

    select
        sb.clinic_id,
        sb.disease_category,
        sb.species,

        sum(sb.sales_usd_disease_category)    as sales_12m,
        sum(sb.sales_volume_disease_category) as volume_12m

    from sales_base sb
    cross join as_of a
    where sb.invoice_month between
          dateadd(month, -11, a.as_of_month)
      and a.as_of_month
    group by sb.clinic_id, sb.disease_category, sb.species

),

clinic_dc_avg as (

    select
        clinic_id,
        disease_category,
        species,
        sales_12m  / 12.0 as clinic_avg_monthly_sales,
        volume_12m / 12.0 as clinic_avg_monthly_volume

    from rolling_12m

),

clinic_total as (

    select
        clinic_id,
        sum(clinic_avg_monthly_sales)  as clinic_total_avg_sales,
        sum(clinic_avg_monthly_volume) as clinic_total_avg_volume

    from clinic_dc_avg
    group by clinic_id

),

clinic_shares as (

    select
        c.clinic_id,
        c.disease_category,
        c.species,
        c.clinic_avg_monthly_sales,
        c.clinic_avg_monthly_volume,
        ct.clinic_total_avg_sales,
        ct.clinic_total_avg_volume,

        c.clinic_avg_monthly_sales
            / nullif(ct.clinic_total_avg_sales, 0)  as clinic_dc_share,
        c.clinic_avg_monthly_volume
            / nullif(ct.clinic_total_avg_volume, 0) as clinic_dc_share_volume

    from clinic_dc_avg c
    left join clinic_total ct 
        using (clinic_id)

),

top_dc as (

    select
        clinic_id,
        disease_category as top_category,
        species          as top_species

    from clinic_shares
    qualify row_number() over (
        partition by clinic_id
        order by clinic_avg_monthly_sales desc nulls last, disease_category, species
    ) = 1

),

cluster_dc_avg as (

    select
        cl.tier_group,
        cl.cluster,
        c.disease_category,
        c.species,

        avg(c.clinic_avg_monthly_sales)  as cluster_avg_monthly_sales,
        avg(c.clinic_avg_monthly_volume) as cluster_avg_monthly_volume

    from clinic_dc_avg c
    join clusters cl 
        on c.clinic_id = cl.clinic_id
    group by cl.tier_group, cl.cluster, c.disease_category, c.species

),

cluster_total as (

    select
        tier_group,
        cluster,

        sum(cluster_avg_monthly_sales)  as cluster_total_avg_sales,
        sum(cluster_avg_monthly_volume) as cluster_total_avg_volume

    from cluster_dc_avg
    group by tier_group, cluster

),

cluster_shares as (

    select
        cd.tier_group,
        cd.cluster,
        cd.disease_category,
        cd.species,
        cd.cluster_avg_monthly_sales,
        cd.cluster_avg_monthly_volume,

        cd.cluster_avg_monthly_sales
            / nullif(ct.cluster_total_avg_sales, 0)  as cluster_dc_share,
        cd.cluster_avg_monthly_volume
            / nullif(ct.cluster_total_avg_volume, 0) as cluster_dc_share_volume

    from cluster_dc_avg cd
    left join cluster_total ct
        on cd.tier_group = ct.tier_group
       and cd.cluster    = ct.cluster

),

current_scenario as (

    select
        sb.clinic_id,
        sb.disease_category,
        sb.species,
        sb.scenario_disease_category

    from sales_base sb
    cross join as_of a
    where sb.invoice_month = a.as_of_month

),

next_scenarios as (

    select
        clinic_id,
        disease_category,
        species,
        invoice_month,
        scenario_disease_category,
        
        lead(scenario_disease_category) over (
            partition by clinic_id, disease_category, species
            order by invoice_month
        ) as next_scenario

    from sales_base

),

lost_starts as (

    select
        clinic_id,
        disease_category,
        species,
        min(invoice_month) as lost_start_month
    from next_scenarios
    where scenario_disease_category in ('Lost', 'Long term lost')
         and next_scenario          in ('Lost', 'Long term lost')
    group by clinic_id, disease_category, species

),

lost_window_sales as (

    select
        ls.clinic_id,
        ls.disease_category,
        ls.species,

        sum(sb.sales_usd_disease_category)    as lost_window_12m_sales,
        sum(sb.sales_volume_disease_category) as lost_window_12m_volume

    from lost_starts ls
    join sales_base sb
        on  sb.clinic_id        = ls.clinic_id
        and sb.disease_category = ls.disease_category
        and sb.species          = ls.species
        and sb.invoice_month between
                dateadd(month, -15, ls.lost_start_month)
            and dateadd(month,  -5, ls.lost_start_month)
    group by ls.clinic_id, ls.disease_category, ls.species

),

lost_monthly as (

    select
        clinic_id,
        disease_category,
        species,

        lost_window_12m_sales  / 12.0 as lost_monthly_sales,
        lost_window_12m_volume / 12.0 as lost_monthly_volume

    from lost_window_sales

),

ly_sales as (

    select
        sb.clinic_id,
        sb.disease_category,
        sb.species,

        avg(sb.sales_usd_disease_category)    as ly_monthly_sales,
        avg(sb.sales_volume_disease_category) as ly_monthly_volume

    from sales_base sb
    cross join as_of a
    where sb.invoice_month between
          dateadd(month, -24, a.as_of_month)
      and dateadd(month, -13, a.as_of_month)
    group by sb.clinic_id, sb.disease_category, sb.species

),

joined as (

    select
        c.clinic_id,
        c.ship_to_customer_tier,
        c.tier_group,
        c.cluster,
        c.cluster_volume,
        c.sales_segment_in_cluster,
        c.volume_segment_in_cluster,
        c.next_step_cluster,
        c.next_step_cluster_volume,
        c.next_step_segment,
        c.next_step_segment_volume,

        cs.disease_category,
        cs.species,

        cs.clinic_avg_monthly_sales,
        cs.clinic_avg_monthly_volume,
        cs.clinic_total_avg_sales,
        cs.clinic_total_avg_volume,
        cs.clinic_dc_share,
        cs.clinic_dc_share_volume,

        td.top_category,
        td.top_species,

        clsh.cluster_avg_monthly_sales,
        clsh.cluster_avg_monthly_volume,
        clsh.cluster_dc_share,
        clsh.cluster_dc_share_volume,

        cur.scenario_disease_category,

        lm.lost_monthly_sales,
        lm.lost_monthly_volume,

        coalesce(ly.ly_monthly_sales,  0) as ly_monthly_sales,
        coalesce(ly.ly_monthly_volume, 0) as ly_monthly_volume

    from clinic_shares cs
    join clusters c
        on cs.clinic_id = c.clinic_id
    left join top_dc td
        on cs.clinic_id = td.clinic_id
    left join cluster_shares clsh
        on  c.tier_group        = clsh.tier_group
        and c.cluster           = clsh.cluster
        and cs.disease_category = clsh.disease_category
        and cs.species          = clsh.species
    left join current_scenario cur
        on  cs.clinic_id        = cur.clinic_id
        and cs.disease_category = cur.disease_category
        and cs.species          = cur.species
    left join lost_monthly lm
        on  cs.clinic_id        = lm.clinic_id
        and cs.disease_category = lm.disease_category
        and cs.species          = lm.species
    left join ly_sales ly
        on  cs.clinic_id        = ly.clinic_id
        and cs.disease_category = ly.disease_category
        and cs.species          = ly.species

),

with_gap as (

    select
        *,

        case
            when disease_category = top_category
             and species          = top_species
                then greatest(cluster_avg_monthly_sales - clinic_avg_monthly_sales, 0)
            else null
        end as sales_gap

    from joined

),

with_new_total as (

    select
        *,

        clinic_total_avg_sales
            + coalesce( max(sales_gap) over (partition by clinic_id), 0 ) as new_total_sales,
        greatest(clinic_dc_share, cluster_dc_share) as max_share

    from with_gap

),

with_expected as (

    select
        *,

        case
            -- Lost / LTL override: expected = pre-lost avg
            when scenario_disease_category in ('Lost', 'Long term lost')
                 and lost_monthly_sales is not null
                then lost_monthly_sales

            when scenario_disease_category = 'Never happened'
                 and cluster_dc_share < 0.2
                then 0

            when disease_category = top_category
                 and species = top_species
                 and clinic_avg_monthly_sales >= cluster_avg_monthly_sales
                then clinic_avg_monthly_sales

            else max_share * new_total_sales
        end as new_expected_monthly_sales

    from with_new_total

),

final as (

    select
        *,

       case
            when ly_monthly_sales > 0 then
                ((clinic_avg_monthly_sales * 12) - (ly_monthly_sales * 12))
                / (ly_monthly_sales * 12)
            else 0
        end as trend_pct,

        case
            when ly_monthly_volume > 0 then
                ((clinic_avg_monthly_volume * 12) - (ly_monthly_volume * 12))
                / (ly_monthly_volume * 12)
            else 0
        end as trend_pct_volume,

        cast(null as float) as growth_pct,
        cast(null as float) as growth_pct_volume,

        case
            when scenario_disease_category in ('Lost', 'Long term lost')
                 and lost_monthly_sales is not null
                then lost_monthly_sales
            else new_expected_monthly_sales - clinic_avg_monthly_sales
        end as opportunity,

        cast(null as float) as opportunity_volume

    from with_expected

)

select *
from final
order by disease_category,species