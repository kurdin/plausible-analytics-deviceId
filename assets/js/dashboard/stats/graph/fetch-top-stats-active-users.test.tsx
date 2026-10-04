import React, { useEffect, useState } from 'react'
import { render, waitFor } from '@testing-library/react'
import { QueryApiResponse } from '../../api'
import { TestContextProviders } from '../../../../test-utils/app-context-providers'
import {
  formatTopStatsData,
  isGraphableMetric,
  mergeActiveUsersData,
  useTopStatsQuery
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

describe(`${mergeActiveUsersData.name}`, () => {
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

    const merged = mergeActiveUsersData(main, activeUsers)

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

  it('does not merge when only one of them has a comparison', () => {
    const main = response(
      ['visitors'],
      [10],
      {},
      { metrics: [5], change: [100] }
    )
    const activeUsers = response(['dau', 'wau', 'mau'], [1, 2, 3])

    expect(mergeActiveUsersData(main, activeUsers)).toBe(main)
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

describe(`${useTopStatsQuery.name}`, () => {
  const fetchMock = jest.fn()

  const activeUsersRequests = () =>
    fetchMock.mock.calls.filter(([, init]) =>
      String(init?.body ?? '').includes('"mau"')
    ).length

  beforeEach(() => {
    fetchMock.mockImplementation(async (_url: string, init: RequestInit) => {
      const body = JSON.parse((init?.body as string) ?? '{}')
      const data = body.metrics?.includes('mau')
        ? response(['dau', 'wau', 'mau'], [1, 2, 3])
        : response(['visitors'], [10])
      return {
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => data
      }
    })
    global.fetch = fetchMock as unknown as typeof fetch
  })

  // Mimics VisitorGraph: an effect that updates state whenever the top stats
  // data changes. Unstable merged data would re-render this forever.
  function Probe({ onData }: { onData: (d: QueryApiResponse) => void }) {
    const { apiState } = useTopStatsQuery()
    const [, setRenders] = useState(0)

    useEffect(() => {
      if (apiState.data) {
        onData(apiState.data)
        setRenders((n) => n + 1)
      }
    }, [apiState.data, onData])

    return null
  }

  it('merges active users into stable data without re-render loops', async () => {
    const seen: QueryApiResponse[] = []
    const onData = (d: QueryApiResponse) => seen.push(d)

    render(
      <TestContextProviders siteOptions={{ persistentTracking: true }}>
        <Probe onData={onData} />
      </TestContextProviders>
    )

    await waitFor(() =>
      expect(seen.at(-1)?.query.metrics).toEqual([
        'visitors',
        'dau',
        'wau',
        'mau'
      ])
    )
    // one update for the regular stats, one once active users are merged
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(seen.length).toBeLessThanOrEqual(3)
    expect(activeUsersRequests()).toBe(1)
  })

  it('does not request active users without persistent tracking', async () => {
    const seen: QueryApiResponse[] = []

    render(
      <TestContextProviders siteOptions={{ persistentTracking: false }}>
        <Probe onData={(d) => seen.push(d)} />
      </TestContextProviders>
    )

    await waitFor(() => expect(seen.length).toBeGreaterThan(0))
    expect(seen.at(-1)?.query.metrics).toEqual(['visitors'])
    expect(activeUsersRequests()).toBe(0)
  })
})
