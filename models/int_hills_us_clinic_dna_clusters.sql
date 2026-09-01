with

base_rows as (

    select 
        ship_to_account_number,
        ship_to_customer_tier,
        invoice_month,
        disease_category,
        species,
        sales_usd_disease_category,
        sales_volume_disease_category,
        scenario_clinic,
        scenario_disease_category,
        months_since_new_or_recover_scenario_clinic

    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

-- Swap for `select max(invoice_month) from base_rows` if we need to use
-- "latest available month" instead of literal today (e.g. due to data lag).
current_month as (

    select date_trunc('month', current_date()) as now_month

),

df_active_sales as (

    select br.*
    from base_rows br
    cross join current_month cm
    where br.invoice_month between dateadd(month, -11, cm.now_month)
                               and cm.now_month

),

-- Most recent (last-by-invoice_month) client-level streak value within the 12m window
client_last_streak as (

    select
        ship_to_account_number,
        months_since_new_or_recover_scenario_clinic

    from df_active_sales
    qualify row_number() over (
        partition by ship_to_account_number
        order by invoice_month desc
    ) = 1

),

-- Client-level 12m sales/volume sums and DC breadth, summed over the rolling-window rows
clinic_agg as (

    select
        ship_to_account_number,

        max(ship_to_customer_tier)           as ship_to_customer_tier,
        sum(sales_usd_disease_category)      as sales_12m,
        sum(sales_volume_disease_category)   as volume_12m,
        count(distinct disease_category)     as num_disease_categories

    from df_active_sales
    group by ship_to_account_number

),

clinic_monthly as (

    select
        ca.ship_to_account_number,
        ca.ship_to_customer_tier,
        ca.num_disease_categories,

        least(coalesce(cls.months_since_new_or_recover_scenario_clinic, 12), 12) as active_months,
        ca.sales_12m
            / nullif(least(coalesce(cls.months_since_new_or_recover_scenario_clinic, 12), 12), 0)
            as monthly_sales,
        ca.volume_12m
            / nullif(least(coalesce(cls.months_since_new_or_recover_scenario_clinic, 12), 12), 0)
            as monthly_volume

    from clinic_agg ca
    left join client_last_streak cls
        on ca.ship_to_account_number = cls.ship_to_account_number

),

-- OUTLIER THRESHOLDS -- SALES. Top 5% (A/B) / top 3% (C) of monthly_sales

ab_outlier_threshold as (

    select percentile_cont(0.95) within group (order by monthly_sales) as p95
    from clinic_monthly
    where ship_to_customer_tier in ('A', 'B')

),

c_outlier_threshold as (

    select percentile_cont(0.97) within group (order by monthly_sales) as p97
    from clinic_monthly
    where ship_to_customer_tier = 'C'

),

ab_size_thresholds as (

    select
        percentile_cont(0.33) within group (order by cm.monthly_sales) as p33,
        percentile_cont(0.60) within group (order by cm.monthly_sales) as p60,
        percentile_cont(0.90) within group (order by cm.monthly_sales) as p90
        
    from clinic_monthly cm
    cross join ab_outlier_threshold t
    where cm.ship_to_customer_tier in ('A', 'B')
      and cm.monthly_sales < t.p95

),

c_size_thresholds as (

    select
        percentile_cont(0.30) within group (order by cm.monthly_sales) as p30,
        percentile_cont(0.70) within group (order by cm.monthly_sales) as p70

    from clinic_monthly cm
    cross join c_outlier_threshold t
    where cm.ship_to_customer_tier = 'C'
      and cm.monthly_sales < t.p97

),

-- OUTLIER THRESHOLDS -- VOLUME. Same mechanism as sales, applied to monthly_volume.

ab_outlier_threshold_vol as (

    select percentile_cont(0.95) within group (order by monthly_volume) as p95
    from clinic_monthly
    where ship_to_customer_tier in ('A', 'B')

),

c_outlier_threshold_vol as (

    select percentile_cont(0.97) within group (order by monthly_volume) as p97
    from clinic_monthly
    where ship_to_customer_tier = 'C'

),

ab_size_thresholds_vol as (

    select
        percentile_cont(0.33) within group (order by cm.monthly_volume) as p33,
        percentile_cont(0.60) within group (order by cm.monthly_volume) as p60,
        percentile_cont(0.90) within group (order by cm.monthly_volume) as p90

    from clinic_monthly cm
    cross join ab_outlier_threshold_vol t
    where cm.ship_to_customer_tier in ('A', 'B')
      and cm.monthly_volume < t.p95

),

c_size_thresholds_vol as (

    select
        percentile_cont(0.30) within group (order by cm.monthly_volume) as p30,
        percentile_cont(0.70) within group (order by cm.monthly_volume) as p70

    from clinic_monthly cm
    cross join c_outlier_threshold_vol t
    where cm.ship_to_customer_tier = 'C'
      and cm.monthly_volume < t.p97

),

-- SALES SEGMENT (size tier, including Outliers) + VOLUME SEGMENT in parallel.
sales_segment as (

    select
        cm.*,

        case
            when cm.ship_to_customer_tier in ('A', 'B') then
                case
                    when cm.monthly_sales >= abo.p95 then 'Outliers'
                    when cm.monthly_sales <= abt.p33 then 'Small'
                    when cm.monthly_sales <= abt.p60 then 'Medium'
                    when cm.monthly_sales <= abt.p90 then 'Large'
                    else 'XLarge'
                end
            when cm.ship_to_customer_tier = 'C' then
                case
                    when cm.monthly_sales >= co.p97 then 'Outliers'
                    when cm.monthly_sales <= ct.p30 then 'Small'
                    when cm.monthly_sales <= ct.p70 then 'Medium'
                    else 'Large'
                end
        end as sales_segment,

        case
            when cm.ship_to_customer_tier in ('A', 'B') then
                case
                    when cm.monthly_volume >= abov.p95 then 'Outliers'
                    when cm.monthly_volume <= abtv.p33 then 'Small'
                    when cm.monthly_volume <= abtv.p60 then 'Medium'
                    when cm.monthly_volume <= abtv.p90 then 'Large'
                    else 'XLarge'
                end
            when cm.ship_to_customer_tier = 'C' then
                case
                    when cm.monthly_volume >= cov.p97 then 'Outliers'
                    when cm.monthly_volume <= ctv.p30 then 'Small'
                    when cm.monthly_volume <= ctv.p70 then 'Medium'
                    else 'Large'
                end
        end as cluster_volume

    from clinic_monthly cm
    cross join ab_outlier_threshold     abo
    cross join ab_size_thresholds       abt
    cross join c_outlier_threshold      co
    cross join c_size_thresholds        ct
    cross join ab_outlier_threshold_vol abov
    cross join ab_size_thresholds_vol   abtv
    cross join c_outlier_threshold_vol  cov
    cross join c_size_thresholds_vol    ctv

),

-- ASSORTMENT SEGMENTATION (SALES ONLY) 
assortment_thresholds as (

    select
        (ship_to_customer_tier in ('A', 'B')) as is_ab,
        sales_segment,
        percentile_cont(0.25) within group (order by num_disease_categories) as p25_dc

    from sales_segment
    where (ship_to_customer_tier in ('A', 'B') and sales_segment in ('Small', 'Medium', 'Large', 'XLarge'))
       or (ship_to_customer_tier = 'C' and sales_segment = 'Large')
    group by 1, sales_segment

),

with_assortment as (

    select
        ss.*,
        at.p25_dc,

        case
            when ss.sales_segment = 'Outliers' then null
            when ss.ship_to_customer_tier = 'C' and ss.sales_segment in ('Small', 'Medium') then null
            when at.p25_dc is null then null
            when ss.num_disease_categories <= at.p25_dc then 'Reduce Assortment'
            else 'Large Assortment'
        end as assortment_segment

    from sales_segment ss
    left join assortment_thresholds at
        on  (ss.ship_to_customer_tier in ('A', 'B')) = at.is_ab
        and ss.sales_segment = at.sales_segment

),

clustered as (

    select
        ship_to_account_number,
        ship_to_customer_tier,
        monthly_sales,
        monthly_volume,
        num_disease_categories,

        case
            when assortment_segment is not null
                then sales_segment || ' - ' || assortment_segment
            else sales_segment
        end as cluster,
        -- Plain size bucket -- no assortment axis, no dash suffix, no flattening needed at final output.
        cluster_volume

    from with_assortment

),

-- Intra-cluster SALES percentile
cluster_percentiles as (

    select
        cluster,
        percentile_cont(0.25) within group (order by monthly_sales) as p25,
        percentile_cont(0.75) within group (order by monthly_sales) as p75

    from clustered
    where cluster <> 'Outliers'
    group by cluster

),

-- Intra-cluster VOLUME percentile 
cluster_percentiles_volume as (

    select
        cluster_volume,
        percentile_cont(0.25) within group (order by monthly_volume) as p25_vol,
        percentile_cont(0.75) within group (order by monthly_volume) as p75_vol

    from clustered
    where cluster_volume <> 'Outliers'
    group by cluster_volume

),

segmented as (

    select
        c.ship_to_account_number,
        c.ship_to_customer_tier,
        c.monthly_sales  as avg_monthly_sales,
        c.monthly_volume as avg_monthly_volume,
        c.cluster,
        c.cluster_volume,

        case
            when c.cluster = 'Outliers'    then 'Outliers'
            when c.monthly_sales <= cp.p25 then 'Below 25th'
            when c.monthly_sales >  cp.p75 then 'Above 75th'
            else 'Between 25th-75th'
        end as sales_segment_in_cluster,

        case
            when c.cluster_volume = 'Outliers'     then 'Outliers'
            when c.monthly_volume <= cpv.p25_vol    then 'Below 25th'
            when c.monthly_volume >  cpv.p75_vol    then 'Above 75th'
            else 'Between 25th-75th'
        end as volume_segment_in_cluster

    from clustered c
    left join cluster_percentiles cp
        on c.cluster = cp.cluster
    left join cluster_percentiles_volume cpv
        on c.cluster_volume = cpv.cluster_volume

),

-- ACTION SUMMARY
actions_cleaned as (

    select
        "SHIP TO ACCOUNT NUMBER" as ship_to_account_number,
        to_date("INVOICE MONTH YEAR") as invoice_month,
        coalesce(cast("NUM VISIT CALLS" as decimal), 0) as num_visit_calls,
        coalesce(cast("NUM EDUCATIONS" as decimal), 0)  as num_educations,
        coalesce(cast("NUM SAMPLES" as decimal), 0)     as num_samples,
        coalesce(cast("NUM TPRS" as decimal), 0)        as num_tprs

    from SBX_EXT_SALES_HUB.HILLS_US.con_hills_us_clinic_dna_executive_summary

),

totals as (

    select
        ship_to_account_number,
        sum(num_visit_calls) as total_visits,
        sum(num_educations)  as total_educations,
        sum(num_samples)     as total_samples,
        sum(num_tprs)        as total_tprs
    from actions_cleaned
    group by ship_to_account_number

),

last_actions as (

    select
        ship_to_account_number,
        max(case when num_visit_calls > 0 then invoice_month end) as last_visit,
        max(case when num_educations  > 0 then invoice_month end) as last_education,
        max(case when num_samples     > 0 then invoice_month end) as last_sample,
        max(case when num_tprs        > 0 then invoice_month end) as last_tpr
    from actions_cleaned
    group by ship_to_account_number

),        

action_summary as (

    select
        t.ship_to_account_number,
        t.total_visits,
        t.total_educations,
        t.total_samples,
        t.total_tprs,
        la.last_visit,
        la.last_education,
        la.last_sample,
        la.last_tpr

    from totals t
    left join last_actions la
        on t.ship_to_account_number = la.ship_to_account_number

),

final as (

    select
        s.ship_to_account_number,
        s.ship_to_customer_tier,
        coalesce(s.avg_monthly_sales, 0)  as avg_monthly_sales,
        coalesce(s.avg_monthly_volume, 0) as avg_monthly_volume,

        trim(split_part(s.cluster, '-', 1)) as cluster,
        s.sales_segment_in_cluster,
        s.cluster_volume,
        s.volume_segment_in_cluster,

        a.total_visits,
        a.total_educations,
        a.total_samples,
        a.total_tprs,
        a.last_visit,
        a.last_education,
        a.last_sample,
        a.last_tpr

    from segmented s
    left join action_summary a
        on s.ship_to_account_number = a.ship_to_account_number

)

select * from final