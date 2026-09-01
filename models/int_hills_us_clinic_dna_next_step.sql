with base as (

    select
        ship_to_account_number,
        ship_to_customer_tier,
        cluster,
        cluster_volume,
        sales_segment_in_cluster,
        volume_segment_in_cluster,

        case
            when ship_to_customer_tier = 'A' then 'A'
            when ship_to_customer_tier = 'B' then 'B'
            else 'C'
        end as tier_group

    from SBX_EXT_SALES_HUB.HILLS_US.int_hills_us_clinic_dna_clusters

),

next_step as (

    select
        *,

        -- SALES AXIS

        -- next_step_tier_group: only changes when crossing tiers
        -- (top rung, Above 75th, promoting out of the tier entirely)
        case
            when sales_segment_in_cluster = 'Above 75th'
                and cluster = 'Outliers'
                and tier_group = 'C'
            then 'B'

            when sales_segment_in_cluster = 'Above 75th'
                and cluster = 'Outliers'
                and tier_group = 'B'
            then 'A'
            
            else tier_group -- includes tier A ceiling case: stays 'A'
        end as next_step_tier_group,

        case
            -- top rung + Above 75th -> cross tier, land at Small (C/B) or
            -- stay Outliers (A ceiling)
            when sales_segment_in_cluster = 'Above 75th'
                and cluster = 'Outliers'
                and tier_group in ('C','B')
            then 'Small'

            when sales_segment_in_cluster = 'Above 75th'
                and cluster = 'Outliers'
                and tier_group = 'A'
            then 'Outliers' -- ceiling, holds

            -- promote to next cluster rung (XLarge folded in with Large)
            when sales_segment_in_cluster = 'Above 75th'
                and cluster in ('Small','Medium','Large','XLarge')
            then case cluster
                    when 'Small'  then 'Medium'
                    when 'Medium' then 'Large'
                    when 'Large'  then 'Outliers'
                    when 'XLarge' then 'Outliers'
                end

            -- not at Above 75th yet: cluster unchanged
            else cluster
        end as next_step_cluster,

        case
            when sales_segment_in_cluster = 'Above 75th'
                and cluster = 'Outliers'
                and tier_group = 'A'
            then 'Above 75th' -- ceiling, holds exactly in place

            when sales_segment_in_cluster = 'Above 75th'
                then 'Below 25th' -- every other promotion/cross resets to bottom

            when sales_segment_in_cluster = 'Below 25th'
                then 'Between 25th-75th'

            when sales_segment_in_cluster = 'Between 25th-75th'
                then 'Above 75th'

            else sales_segment_in_cluster
        end as next_step_segment,

        -- VOLUME AXIS
        case
            when volume_segment_in_cluster = 'Above 75th'
                and cluster_volume = 'Outliers'
                and tier_group = 'C'
            then 'B'
            
            when volume_segment_in_cluster = 'Above 75th'
                and cluster_volume = 'Outliers'
                and tier_group = 'B'
            then 'A'

            else tier_group
        end as next_step_tier_group_volume,

        case
            when volume_segment_in_cluster = 'Above 75th'
                and cluster_volume = 'Outliers'
                and tier_group in ('C','B')
            then 'Small'

            when volume_segment_in_cluster = 'Above 75th'
                and cluster_volume = 'Outliers'
                and tier_group = 'A'
            then 'Outliers'

            when volume_segment_in_cluster = 'Above 75th'
                and cluster_volume in ('Small','Medium','Large','XLarge')
            then case cluster_volume
                    when 'Small'  then 'Medium'
                    when 'Medium' then 'Large'
                    when 'Large'  then 'Outliers'
                    when 'XLarge' then 'Outliers'
                end

            else cluster_volume
        end as next_step_cluster_volume,

        case
            when volume_segment_in_cluster = 'Above 75th'
                and cluster_volume = 'Outliers'
                and tier_group = 'A'
            then 'Above 75th'

            when volume_segment_in_cluster = 'Above 75th'
                then 'Below 25th'

            when volume_segment_in_cluster = 'Below 25th'
                then 'Between 25th-75th'

            when volume_segment_in_cluster = 'Between 25th-75th'
                then 'Above 75th'

            else volume_segment_in_cluster
        end as next_step_segment_volume

    from base

)

select * from next_step