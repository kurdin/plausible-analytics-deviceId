import { UseQueryResult } from '@tanstack/react-query'
import { QueryApiResponse } from '../../api'
import {
  formatTopStatsData,
  isGraphableMetric,
  mergeActiveUsers
} from './fetch-top-stats'

function response(
  metrics: QueryApiResponse['query']['metrics'],
  values: number[],
  extra: Partial<QueryApiResponse> = {},
  comparison?: { metrics: number[]; change: number[] }
): QueryApiResponse {
  return {
    query: {
      metrics,
      dimensions: [],
      date_range: ['2026-01-01T00:00:00', '2026-01-28T23:59:59']
    },
    meta: {},
    results: [{ metrics: values, dimensions: [], comparison }],
    extraContext: { isRealtime: false, hasConversionGoalFilter: false },
    ...extra
  }
}

function state(data?: QueryApiResponse, isFetching = false) {
  return { data, isFetching } as UseQueryResult<QueryApiResponse>
}

describe(`${mergeActiveUsers.name}`, () => {
  it('appends active user metrics, comparisons and warnings to the top stats', () => {
    const main = response(
      ['visitors', 'visits'],
      [10, 12],
      { meta: { imports_included: true } },
      { metrics: [5, 6], change: [100, 100] }
    )
    const activeUsers = response(
      ['dau', 'wau', 'mau'],
      [1, 4, 9],
      {
        meta: {
          metric_warnings: {
            mau: { code: 'persistent_tracking_partial', message: 'x' }
          }
        }
      },
      { metrics: [1, 2, 3], change: [0, 100, 200] }
    )

    const merged = mergeActiveUsers(state(main), state(activeUsers)).data!

    expect(merged.query.metrics).toEqual([
      'visitors',
      'visits',
      'dau',
      'wau',
      'mau'
    ])
    expect(merged.results[0].metrics).toEqual([10, 12, 1, 4, 9])
    expect(merged.results[0].comparison).toEqual({
      metrics: [5, 6, 1, 2, 3],
      change: [100, 100, 0, 100, 200]
    })
    expect(merged.meta.imports_included).toBe(true)
    expect(merged.meta.metric_warnings?.mau?.code).toBe(
      'persistent_tracking_partial'
    )
  })

  it('keeps the regular top stats while active users are not loaded', () => {
    const main = response(['visitors'], [10])
    const merged = mergeActiveUsers(state(main), state(undefined, true))
    expect(merged.data).toBe(main)
  })

  it('reports fetching while either query is fetching', () => {
    const merged = mergeActiveUsers(
      state(response(['visitors'], [10])),
      state(response(['dau', 'wau', 'mau'], [1, 2, 3]), true)
    )
    expect(merged.isFetching).toBe(true)
  })
})

describe(`${isGraphableMetric.name}`, () => {
  it('graphs active user metrics only per day, week or month', () => {
    expect(isGraphableMetric('mau', 'day')).toBe(true)
    expect(isGraphableMetric('mau', 'week')).toBe(true)
    expect(isGraphableMetric('mau', 'month')).toBe(true)
    expect(isGraphableMetric('mau', 'hour')).toBe(false)
    expect(isGraphableMetric('dau', 'minute')).toBe(false)
    expect(isGraphableMetric('visitors', 'hour')).toBe(true)
  })

  it('marks top stat tiles accordingly', () => {
    const data = response(['visitors', 'dau'], [10, 1])
    const graphable = (interval: string) =>
      formatTopStatsData(data, { selectedInterval: interval }).topStats.map(
        (s) => s.graphable
      )

    expect(graphable('day')).toEqual([true, true])
    expect(graphable('hour')).toEqual([true, false])
  })
})
