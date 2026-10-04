import * as api from '../../api'
import { DashboardState } from '../../dashboard-state'
import { getMetricLabel, Metric } from '../metrics'
import {
  ComparisonMode,
  DashboardPeriod,
  isComparisonEnabled,
  isComparisonForbidden
} from '../../dashboard-time-periods'
import { PlausibleSite, useSiteContext } from '../../site-context'
import { createStatsQuery, StatsQuery } from '../../stats-query'
import {
  hasConversionGoalFilter,
  hasPageFilter,
  isRealTimeDashboard
} from '../../util/filters'
import { StatsReportQueryKey, useQueryApi } from '../../hooks/use-query-api'
import { useDashboardStateContext } from '../../dashboard-state-context'
import { Interval } from './intervals'
import { useMemo } from 'react'
import { UseQueryResult } from '@tanstack/react-query'

/**
 * Rolling active users (persistent tracking only). They are fetched with a
 * separate query because the API doesn't allow combining them with other
 * metrics, and they don't support imported data (which would otherwise turn
 * off imports for all the other top stats).
 */
export const ACTIVE_USER_METRICS: Metric[] = ['dau', 'wau', 'mau']

const ACTIVE_USER_GRAPH_INTERVALS: string[] = [
  Interval.day,
  Interval.week,
  Interval.month
]

export function isActiveUserMetric(metric: Metric): boolean {
  return ACTIVE_USER_METRICS.includes(metric)
}

/** Active user metrics have no hourly or per-minute values. */
export function isGraphableMetric(
  metric: Metric,
  interval: string | undefined
): boolean {
  return (
    !isActiveUserMetric(metric) ||
    (!!interval && ACTIVE_USER_GRAPH_INTERVALS.includes(interval))
  )
}

export function useTopStatsQuery() {
  const site = useSiteContext()
  const { dashboardState } = useDashboardStateContext()

  const topStatsQueryKey: StatsReportQueryKey = [
    'top-stats',
    {
      dashboardState,
      reportParams: {
        metrics: chooseMetrics(site, dashboardState),
        dimensions: [],
        include: { imports_meta: true }
      }
    }
  ]

  const { apiState, isRealtimeSilentUpdate } = useQueryApi(
    site,
    topStatsQueryKey,
    { getStatsQuery: getTopStatsQuery }
  )

  const activeUsersEnabled =
    site.persistentTracking && !isRealTimeDashboard(dashboardState)

  const activeUsersQueryKey: StatsReportQueryKey = [
    'active-users',
    {
      dashboardState,
      reportParams: {
        metrics: ACTIVE_USER_METRICS,
        dimensions: [],
        include: {}
      }
    }
  ]

  const { apiState: activeUsersApiState } = useQueryApi(
    site,
    activeUsersQueryKey,
    { getStatsQuery: getTopStatsQuery, enabled: activeUsersEnabled }
  )

  // Don't show the previous period's active users (TanStack placeholder data)
  // next to the new period's regular stats.
  const activeUsersReady =
    activeUsersEnabled &&
    !!activeUsersApiState.data &&
    !(activeUsersApiState.isPlaceholderData && !apiState.isPlaceholderData)

  // Depend on the stable `data` references only: useQuery returns a new
  // result object on every render, which would re-create the merged data on
  // every render and loop through effects that depend on it.
  const mergedData = useMemo(
    () =>
      activeUsersReady && apiState.data && activeUsersApiState.data
        ? mergeActiveUsersData(apiState.data, activeUsersApiState.data)
        : apiState.data,
    [activeUsersReady, apiState.data, activeUsersApiState.data]
  )

  const mergedApiState = {
    ...apiState,
    data: mergedData,
    isFetching:
      apiState.isFetching ||
      (activeUsersEnabled && activeUsersApiState.isFetching)
  } as UseQueryResult<api.QueryApiResponse>

  return {
    apiState: mergedApiState,
    isRealtimeSilentUpdate,
    activeUsersPending: activeUsersEnabled && !activeUsersReady
  }
}

/**
 * Appends the active user metrics to the regular top stats response, so they
 * render as extra tiles. Returns the regular response unchanged if the two
 * can't be combined (no rows, or only one of them has a comparison).
 */
export function mergeActiveUsersData(
  main: api.QueryApiResponse,
  activeUsers: api.QueryApiResponse
): api.QueryApiResponse {
  const mainRow = main.results[0]
  const activeUsersRow = activeUsers.results[0]

  if (
    !mainRow ||
    !activeUsersRow ||
    !!mainRow.comparison !== !!activeUsersRow.comparison
  ) {
    return main
  }

  const comparison =
    mainRow.comparison && activeUsersRow.comparison
      ? {
          metrics: [
            ...mainRow.comparison.metrics,
            ...activeUsersRow.comparison.metrics
          ],
          change: [
            ...mainRow.comparison.change,
            ...activeUsersRow.comparison.change
          ]
        }
      : undefined

  return {
    ...main,
    query: {
      ...main.query,
      metrics: [...main.query.metrics, ...activeUsers.query.metrics]
    },
    meta: {
      ...main.meta,
      metric_warnings: {
        ...(main.meta.metric_warnings ?? {}),
        ...(activeUsers.meta.metric_warnings ?? {})
      }
    },
    results: [
      {
        ...mainRow,
        metrics: [...mainRow.metrics, ...activeUsersRow.metrics],
        comparison
      }
    ]
  }
}

export function getTopStatsQuery(queryKey: StatsReportQueryKey): StatsQuery {
  const [_reportId, keyOpts] = queryKey
  const { dashboardState, reportParams } = keyOpts

  const statsQuery = createStatsQuery(dashboardState, reportParams)

  if (
    !isComparisonEnabled(dashboardState.comparison) &&
    !isComparisonForbidden({
      period: dashboardState.period,
      segmentIsExpanded: false
    })
  ) {
    statsQuery.include.compare = ComparisonMode.previous_period
  }

  if (isRealTimeDashboard(dashboardState)) {
    statsQuery.date_range = DashboardPeriod.realtime_30m
  }

  return statsQuery
}

export function chooseMetrics(
  site: Pick<PlausibleSite, 'revenueGoals'>,
  dashboardState: DashboardState
): Metric[] {
  const revenueMetrics: Metric[] =
    site.revenueGoals.length > 0 ? ['total_revenue', 'average_revenue'] : []

  if (
    isRealTimeDashboard(dashboardState) &&
    hasConversionGoalFilter(dashboardState)
  ) {
    return ['visitors', 'events']
  } else if (isRealTimeDashboard(dashboardState)) {
    return ['visitors', 'pageviews']
  } else if (hasConversionGoalFilter(dashboardState)) {
    return ['visitors', 'events', ...revenueMetrics, 'conversion_rate']
  } else if (hasPageFilter(dashboardState)) {
    return [
      'visitors',
      'visits',
      'pageviews',
      'bounce_rate',
      'scroll_depth',
      'time_on_page'
    ]
  } else {
    return [
      'visitors',
      'visits',
      'pageviews',
      'views_per_visit',
      'bounce_rate',
      'visit_duration'
    ]
  }
}

function getTopStatMetricLabel(
  metricKey: Metric,
  { isRealtime, hasConversionGoalFilter }: api.ExtraContext
) {
  const metricLabelSuffix = isRealtime ? ' (last 30 min)' : ''

  return `${getMetricLabel(metricKey, { hasConversionGoalFilter })}${metricLabelSuffix}`
}

type TopStatItem = {
  metric: Metric
  value: api.MetricValue
  name: string
  graphable: boolean
  change?: number
  comparisonValue?: number
}

export function formatTopStatsData(
  topStatsResponse: api.QueryApiResponse,
  { selectedInterval }: { selectedInterval?: string } = {}
) {
  const { query, meta, results, extraContext } = topStatsResponse

  const topStats: TopStatItem[] = []

  for (let i = 0; i < query.metrics.length; i++) {
    const metricKey = query.metrics[i]
    topStats.push({
      metric: metricKey,
      value: results[0].metrics[i],
      name: getTopStatMetricLabel(metricKey, extraContext),
      graphable: isGraphableMetric(metricKey, selectedInterval),
      change: results[0].comparison?.change[i],
      comparisonValue: results[0].comparison?.metrics[i]
    })
  }

  const [from, to] = query.date_range.map((d) => d.split('T')[0])

  const comparingFrom = query.comparison_date_range
    ? query.comparison_date_range[0].split('T')[0]
    : null
  const comparingTo = query.comparison_date_range
    ? query.comparison_date_range[1].split('T')[0]
    : null

  const timeRange = getPartialDayTimeRange(query.date_range)

  const comparisonTimeRange = query.comparison_date_range
    ? getPartialDayTimeRange(query.comparison_date_range as [string, string])
    : null

  return {
    topStats,
    meta,
    from,
    to,
    comparingFrom,
    comparingTo,
    timeRange,
    comparisonTimeRange
  }
}

const END_OF_DAY = '23:59:59'

// Returns "until HH:MM" when the date range is a partial day (period=day for
// today, where the range is trimmed to the current time). Returns null otherwise.
export function getPartialDayTimeRange(
  dateRange: [string, string]
): string | null {
  const [startIso, endIso] = dateRange
  if (!endIso.includes('T')) return null

  const [startDate, endDate] = [startIso, endIso].map(
    (iso) => iso.split('T')[0]
  )
  if (startDate !== endDate) return null

  const endTime = endIso.split('T')[1]
  if (endTime.startsWith(END_OF_DAY)) return null

  return `until ${endTime.substring(0, 5)}`
}
