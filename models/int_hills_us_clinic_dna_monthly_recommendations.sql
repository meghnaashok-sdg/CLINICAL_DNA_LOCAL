with 

clinic_info as (

    select distinct
        ship_to_account_number,
        ship_to_account_name
    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_recommendation_setup

),

final_opportunity as (

    select * from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_final_opportunity

),

latest_forecast_month as (

    select max(forecast_month) as max_forecast_month
    from final_opportunity

),

latest_forecast as (

    select fo.*
    from final_opportunity fo
    cross join latest_forecast_month lfm
    where fo.forecast_month = lfm.max_forecast_month

),

reference_date as (

    select current_date() as ref_date

),

prior_pool_membership as (

    

    

    select
        cast(null as varchar) as ship_to_account_number,
        cast(0 as number)     as in_sample_pool_recently,
        cast(0 as number)     as in_education_pool_recently
    where 1 = 0

    

),

with_recency as (

    select
        lf.*,
        rd.ref_date,
        
        coalesce(datediff('day', lf.last_visit, rd.ref_date), 365)      as days_since_visit,
        coalesce(datediff('day', lf.last_education, rd.ref_date), 365)  as days_since_education,
        coalesce(datediff('day', lf.last_sample, rd.ref_date), 365)     as days_since_sample,
        
        coalesce(datediff('day', lf.last_education, rd.ref_date), 365) / 30.0 as months_since_education,
        coalesce(datediff('day', lf.last_sample, rd.ref_date), 365)    / 30.0 as months_since_sample

    from latest_forecast lf
    cross join reference_date rd

),

with_rules as (

    select
        *,

        -- TALK WEIGHT
        case

            when tier_group = 'A' and cluster='XLarge' then 5
            when tier_group = 'A' and cluster='Large' then 4
            when tier_group = 'A' and cluster='Medium' then 3
            when tier_group = 'A' and cluster='Small' then 2
            when tier_group = 'A' and cluster='Outliers' then 1

            when tier_group = 'B' and cluster='XLarge' then 4
            when tier_group = 'B' and cluster='Large' then 3
            when tier_group = 'B' and cluster='Medium' then 2
            when tier_group = 'B' and cluster='Small' then 1
            when tier_group = 'B' and cluster='Outliers' then 1

            when tier_group = 'C' and cluster='XLarge' then 3
            when tier_group = 'C' and cluster='Large' then 2
            when tier_group = 'C' and cluster='Medium' then 1
            when tier_group = 'C' and cluster='Small' then 0
            when tier_group = 'C' and cluster='Outliers' then 0

            else 0

        end as talk_weight,

        -- VISIT WEIGHT
        case

            when tier_group='A' and cluster='XLarge' then 12
            when tier_group='A' and cluster='Large' then 9
            when tier_group='A' and cluster='Medium' then 6
            when tier_group='A' and cluster='Small' then 3
            when tier_group='A' and cluster='Outliers' then 3

            when tier_group='B' and cluster='XLarge' then 8
            when tier_group='B' and cluster='Large' then 6
            when tier_group='B' and cluster='Medium' then 4
            when tier_group='B' and cluster='Small' then 2
            when tier_group='B' and cluster='Outliers' then 2

            when tier_group='C' and cluster='XLarge' then 4
            when tier_group='C' and cluster='Large' then 3
            when tier_group='C' and cluster='Medium' then 2
            when tier_group='C' and cluster='Small' then 1
            when tier_group='C' and cluster='Outliers' then 1

            else 1

        end as visit_weight,
        
        -- VISIT FREQUENCY
        case

            when tier_group='A' then 30
            when tier_group='B' then 45
            else 60

        end as visit_freq_days,

        -- EDUCATION FREQUENCY
        12 as education_freq_months,

        -- SAMPLE FREQUENCY
        case

            when tier_group in ('A','B') then 8
            else 12

        end as sample_freq_months 

    from with_recency

),

with_features as (

    select
        wr.*,

        wr.new_expected_12_months_sales / 2.0 as expected_6m,
        wr.final_monthly_opportunity          as opp_next_month,

        case
            when wr.ly_monthly_sales > 0
            then ((wr.new_expected_12_months_sales / 12.0) - wr.ly_monthly_sales)
                 / wr.ly_monthly_sales * 100.0
            else 0
        end as growth_pct,

        case
            when wr.ly_monthly_sales * 12 > 0
            then ((wr.clinic_avg_monthly_sales * 12) - (wr.ly_monthly_sales * 12))
                 / (wr.ly_monthly_sales * 12) * 100.0
            else 0
        end as trend_pct,

        case
            when upper(cast(wr.scenario_disease_category as varchar)) = 'NEW' then 100.0
            else 0.0
        end as pct_new_prod

    from with_rules wr

),

pct_ranks as (

    select
        wf.*,

        cume_dist() over (
            partition by wf.ship_to_sales_territory_description, wf.tier_group
            order by wf.expected_6m
        ) * 100 as pct_opportunity,

        cume_dist() over (
            partition by wf.ship_to_sales_territory_description, wf.tier_group
            order by wf.growth_pct
        ) * 100 as pct_growth,

        cume_dist() over (
            partition by wf.ship_to_sales_territory_description, wf.tier_group
            order by wf.trend_pct
        ) * 100 as pct_trend,

        cume_dist() over (
            partition by wf.ship_to_sales_territory_description, wf.tier_group
            order by wf.pct_new_prod
        ) * 100 as pct_new

    from with_features wf

),

row_scored as (

    select
        pr.*,

        0.25 * pr.pct_opportunity
            + 0.25 * pr.pct_growth
            + 0.25 * pr.pct_trend
            + 0.25 * pr.pct_new as base_score,

        case
            when (pr.months_since_education / nullif(pr.education_freq_months, 0)) >= 1
            then (
                    least(pr.months_since_education / nullif(pr.education_freq_months, 0), 1.5) - 1.0
                 ) * 40.0
            else 0.0
        end as anxiety_bonus,

        power(greatest(pr.final_monthly_opportunity, 0), 1.0/3.0) as abs_multiplier,

        greatest(
            1 +
            case
                when pr.ly_monthly_sales > 0
                then ((pr.new_expected_12_months_sales / 12.0) - pr.ly_monthly_sales) / pr.ly_monthly_sales
                else 0
            end,
            0.1
        ) as visit_growth_mult

    from pct_ranks pr

),

row_scored_final as (

    select
        rs.*,
        (rs.base_score + rs.anxiety_bonus) * rs.abs_multiplier as edu_score_raw,

        rs.opp_next_month
            * rs.visit_growth_mult
            * power(rs.days_since_visit / nullif(rs.visit_freq_days, 0), 2) as visit_score_raw

    from row_scored rs

),

row_edu_normalized as (

    select
        rsf.*,

        case
            when max(rsf.edu_score_raw) over (
                     partition by rsf.ship_to_sales_territory_description
                 ) > 0
            then rsf.edu_score_raw
                 / max(rsf.edu_score_raw) over (
                       partition by rsf.ship_to_sales_territory_description
                   ) * 100
            else 0
        end as edu_score_norm_unthresholded

    from row_scored_final rsf

),

row_edu_final as (

    select
        *,

        case
            when edu_score_norm_unthresholded < 25 then 0.0
            when expected_6m < 300 then 0.0
            else edu_score_norm_unthresholded
        end as edu_score

    from row_edu_normalized

),

row_edu_candidates as (

    select
        *,

        row_number() over (
            partition by ship_to_sales_territory_description
            order by edu_score desc, ship_to_account_number, disease_category, species
        ) as edu_rank,

        ceil(
            count(distinct ship_to_account_number) over (
                partition by ship_to_sales_territory_description
            ) * 0.17
        ) as edu_target

    from row_edu_final
    where edu_score > 0

),

row_edu_selected as (

    select
        ship_to_account_number,
        ship_to_sales_territory_description,
        disease_category,
        species,
        edu_score

    from row_edu_candidates
    where edu_rank <= edu_target

),

row_education_final as (

    select
        rf.ship_to_account_number,
        rf.disease_category,
        rf.species,
        rf.edu_score,
        (sel.ship_to_account_number is not null) as is_education_selected

    from row_edu_final rf
    left join row_edu_selected sel
        on  rf.ship_to_account_number  = sel.ship_to_account_number
        and rf.disease_category        = sel.disease_category
        and rf.species                 = sel.species

),

best_visit_row as (

    select
        ship_to_account_number,
        visit_score_raw

    from row_scored_final
    qualify row_number() over (
        partition by ship_to_account_number
        order by visit_score_raw desc, disease_category, species
    ) = 1

),

clinic_level as (

    select
        wr.ship_to_account_number,
        ci.ship_to_account_name,
        wr.ship_to_sales_territory_description,
        wr.ship_to_customer_tier,
        wr.tier_group,
        wr.cluster,
        
        sum(wr.final_monthly_opportunity)        as total_opportunity,
        sum(wr.final_monthly_opportunity_volume) as total_opportunity_volume,
        
        max(wr.days_since_visit)        as days_since_visit,
        max(wr.days_since_education)    as days_since_education,
        max(wr.days_since_sample)       as days_since_sample,
        max(wr.months_since_education)  as months_since_education,
        max(wr.months_since_sample)     as months_since_sample,
        
        max(wr.talk_weight)             as talk_weight,
        max(wr.visit_freq_days)         as visit_freq_days,
        max(wr.education_freq_months)   as education_freq_months,
        max(wr.sample_freq_months)      as sample_freq_months,

        max(bvr.visit_score_raw)        as visit_score_raw

    from with_rules wr
    left join clinic_info ci
        on wr.ship_to_account_number = ci.ship_to_account_number
    left join best_visit_row bvr
        on wr.ship_to_account_number = bvr.ship_to_account_number
    where wr.ship_to_sales_territory_description is not null
    group by 1, 2, 3, 4, 5, 6

),

scored_clinics as (

    select
        cl.*,
        
        coalesce(ppm.in_sample_pool_recently, 0)    as in_sample_pool_recently,
        coalesce(ppm.in_education_pool_recently, 0) as in_education_pool_recently,

        cl.total_opportunity / 6.0 as opp_next_month,

        cl.days_since_visit / nullif(cl.visit_freq_days, 0) as visit_urgency,

        -- VISIT SCORE
        cl.visit_score_raw as visit_score,

        -- SAMPLE SCORE
        case
            when cl.months_since_sample >= (cl.sample_freq_months * 0.85)
                 and coalesce(ppm.in_sample_pool_recently, 0) = 0
            then cl.total_opportunity / 6.0
            else null
        end as sample_score,

        -- FLAGS
        case
            when cl.days_since_visit < 14 then 1
            else 0
        end as just_visited_flag,

        case
            when cl.days_since_visit >= (cl.visit_freq_days * 0.85)
            then 1
            else 0
        end as visit_eligible,

        case
            when cl.months_since_sample >= (cl.sample_freq_months * 0.85)
                 and coalesce(ppm.in_sample_pool_recently, 0) = 0
            then 1
            else 0
        end as sample_eligible

    from clinic_level cl
    left join prior_pool_membership ppm
        on cl.ship_to_account_number = ppm.ship_to_account_number

),

all_clinic_actions as (

    select
        sc.ship_to_account_number,
        sc.ship_to_account_name,
        sc.ship_to_sales_territory_description,
        sc.ship_to_customer_tier,
        sc.tier_group,
        sc.cluster,
        sc.total_opportunity,
        sc.total_opportunity_volume,
        sc.visit_score,
        sc.sample_score,
        sc.just_visited_flag,
        sc.visit_eligible,
        sc.sample_eligible,
        sc.in_sample_pool_recently,
        sc.in_education_pool_recently,

        case
            when sc.just_visited_flag = 1 then 'POST-VISIT FOLLOW-UP'
            else 'FOLLOW-UP'
        end as action

    from scored_clinics sc

),

sample_ranked as (

    select
        *,

        14 as num_samples_for_tm,
        row_number() over (
            partition by ship_to_sales_territory_description
            order by sample_score desc, ship_to_account_number
        ) as sample_rank
        
    from all_clinic_actions
    where sample_eligible = 1

),

with_samples as (

    select
        ac.*,

        case 
            when sr.sample_rank <= sr.num_samples_for_tm 
            then true 
            else false 
        end as has_sample

    from all_clinic_actions ac
    left join sample_ranked sr
        on  ac.ship_to_account_number              = sr.ship_to_account_number
        and ac.ship_to_sales_territory_description = sr.ship_to_sales_territory_description
        and sr.sample_rank                         <= sr.num_samples_for_tm

),

clinic_actions as (

    select
        ship_to_account_number,
        ship_to_account_name,
        ship_to_sales_territory_description,
        ship_to_customer_tier,
        tier_group,
        cluster,

        case
            when has_sample and action is not null then action || ' + SAMPLE'
            when has_sample and action is null     then 'SAMPLE'
            else action
        end as action,

        has_sample,
        just_visited_flag,
        visit_score,
        sample_score,
        in_sample_pool_recently,
        in_education_pool_recently,
        total_opportunity        as clinic_total_opportunity,
        total_opportunity_volume as clinic_total_opportunity_volume

    from with_samples

),

scenario_data as (

    select * from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_scenario_analysis_joined

),

latest_invoice_month as (

    select max(invoice_month) as max_invoice_month
    from scenario_data

),

dc_last_12m_sales as (

    select
        sd.ship_to_account_number,
        sd.disease_category,
        sd.species,
        sum(sd.sales_usd_disease_category) as dc_last_12m_sales

    from scenario_data sd
    cross join latest_invoice_month lim
    where sd.invoice_month > dateadd(month, -12, lim.max_invoice_month)
        and sd.invoice_month <= lim.max_invoice_month
    group by 1, 2, 3

),

clinic_last_12m_sales as (

    select
        ship_to_account_number,
        sum(dc_last_12m_sales) as clinic_last_12m_sales

    from dc_last_12m_sales
    group by 1

),

dc_share as (

    select
        d.ship_to_account_number,
        d.disease_category,
        d.species,
        d.dc_last_12m_sales,
        c.clinic_last_12m_sales,

        case
            when c.clinic_last_12m_sales > 0
            then round(d.dc_last_12m_sales / c.clinic_last_12m_sales, 6)
            else 0
        end as dc_share_pct

    from dc_last_12m_sales d
    join clinic_last_12m_sales c
        on d.ship_to_account_number = c.ship_to_account_number

),

actions_with_diseases_base as (

    select
        ca.ship_to_account_number,
        ca.ship_to_account_name,
        ca.ship_to_sales_territory_description,
        ca.ship_to_customer_tier,
        ca.tier_group,
        ca.cluster,
        ca.has_sample,
        ca.just_visited_flag,
        ca.visit_score,
        ca.sample_score,
        ca.in_sample_pool_recently,
        ca.in_education_pool_recently,
        ca.clinic_total_opportunity,
        ca.clinic_total_opportunity_volume,
        
        wr.disease_category,
        wr.species,
        wr.final_monthly_opportunity        as disease_opportunity,
        wr.final_monthly_opportunity_volume as disease_opportunity_volume,
        wr.new_expected_12_months_sales     as disease_expected_12m_sales,
        wr.new_expected_12_months_volume    as disease_expected_12m_volume,
        wr.scenario_disease_category,

        coalesce(ref.is_education_selected, false) as is_education_selected,
        ref.edu_score                              as education_score,
        coalesce(ds.dc_share_pct, 0) as dc_share_pct,

        case
            when coalesce(ref.is_education_selected, false) and ca.has_sample
                then 'EDUCATION + SAMPLE'
            when coalesce(ref.is_education_selected, false)
                then 'EDUCATION'
            else ca.action
        end as action

    from clinic_actions ca
    left join with_rules wr
        on  ca.ship_to_account_number              = wr.ship_to_account_number
        and ca.ship_to_sales_territory_description = wr.ship_to_sales_territory_description
    left join row_education_final ref
        on  wr.ship_to_account_number = ref.ship_to_account_number
        and wr.disease_category        = ref.disease_category
        and wr.species                 = ref.species
    left join dc_share ds
        on  ca.ship_to_account_number = ds.ship_to_account_number
        and wr.disease_category        = ds.disease_category
        and wr.species                 = ds.species

),

actions_with_diseases as (

    select
        awd.*,

        case when awd.action ilike '%EDUCATION%' then 1 else 0 end as dc_edu_flag,
        case when awd.has_sample then 1 else 0 end                 as dc_sample_flag,

        -- rep-facing label, internal tone, action prefixed
        case
            -- Footnote *: DC share > 50% -> always Maintain, edu/sample not allowed
            when awd.dc_share_pct > 0.50
                then 'Maintain — Dominant Category'

            -- 10% < DC share <= 50%
            when awd.dc_share_pct > 0.10 then
                case
                    when awd.disease_opportunity <= 0
                        then 'Maintain — Established Category, No Opportunity'
                    when awd.action ilike '%EDUCATION%' and awd.has_sample
                        then 'Education + Sample - Growth Opportunity — Established Category'
                    when awd.action ilike '%EDUCATION%'
                        then 'Education - Growth Opportunity — Established Category'
                    when awd.has_sample
                        then 'Sample - Growth Opportunity — Established Category'
                    else 'Talk - Growth Opportunity — Established Category'
                end

            -- DC share <= 10%
            else
                case
                    when awd.disease_opportunity <= 0
                        then 'Talk — No Opportunity'

                    -- ACTIVE clinics
                    when upper(awd.scenario_disease_category) = 'ACTIVE' then
                        case
                            when awd.dc_share_pct >= 0.01
                                and awd.dc_share_pct <= 0.10 then
                                case
                                    when awd.action ilike '%EDUCATION%' and awd.has_sample
                                        then 'Education + Sample - Growth Opportunity — Emerging Category'
                                    when awd.action ilike '%EDUCATION%'
                                        then 'Education - Growth Opportunity — Emerging Category'
                                    when awd.has_sample
                                        then 'Sample - Growth Opportunity — Emerging Category'
                                    else
                                        'Talk - Growth Opportunity — Emerging Category'
                                end
                            else
                                case
                                    when awd.action ilike '%EDUCATION%' and awd.has_sample
                                        then 'Education + Sample - Low Penetration Opportunity'
                                    when awd.action ilike '%EDUCATION%'
                                        then 'Education - Low Penetration Opportunity'
                                    when awd.has_sample
                                        then 'Sample - Low Penetration Opportunity'
                                    else
                                        'Talk - Low Penetration Opportunity'
                                end
                        end

                    -- Non-active clinics (Recover, Never happened, Long term lost, etc.)
                    else
                        case
                            when awd.action ilike '%EDUCATION%' and awd.has_sample
                                then 'Education + Sample - New Category Opportunity — Not Yet Established'
                            when awd.action ilike '%EDUCATION%'
                                then 'Education - New Category Opportunity — Not Yet Established'
                            when awd.has_sample
                                then 'Sample - New Category Opportunity — Not Yet Established'
                            when awd.dc_share_pct >= 0.01
                                then 'Talk - New Category Opportunity — Not Yet Established'
                            else
                                'Talk - New Category Opportunity - Introduction'
                        end
                end
        end as dc_opportunity_classification

    from actions_with_diseases_base awd

),

with_rankings as (

    select
        *,
        
        row_number() over (
            partition by ship_to_account_number
            order by disease_opportunity desc, disease_expected_12m_sales desc, disease_category, species
        ) as clinic_disease_rank,
        
        row_number() over (
            partition by ship_to_sales_territory_description, disease_category, species
            order by disease_opportunity desc, disease_expected_12m_sales desc, ship_to_account_number
        ) as territory_disease_rank

    from actions_with_diseases

),

final as (

    select
        *,
        
        count(distinct ship_to_account_number) over (
            partition by ship_to_sales_territory_description
        ) as total_clinics_with_actions,
        
        count(distinct case when has_sample then ship_to_account_number end) over (
            partition by ship_to_sales_territory_description
        ) as total_clinics_with_samples

    from with_rankings

)

select *
from final
order by ship_to_sales_territory_description, ship_to_account_number, clinic_disease_rank