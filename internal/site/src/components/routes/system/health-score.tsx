import { Trans, useLingui } from "@lingui/react/macro"
import { ActivityIcon } from "lucide-react"
import { useMemo } from "react"
import { Card } from "@/components/ui/card"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { SystemStatus } from "@/lib/enums"
import { cn } from "@/lib/utils"
import type { ChartData, SystemRecord } from "@/types"

/** Weight given to each metric's contribution to the deduction from a perfect score. */
const WEIGHTS = {
	cpu: 0.3,
	mem: 0.3,
	disk: 0.25,
	swap: 0.15,
}

/** Usage percent (0-100) above which a metric starts costing health points. */
const THRESHOLD = 60

function deduction(percent: number | undefined) {
	if (!percent || percent <= THRESHOLD) {
		return 0
	}
	return Math.min(100, ((percent - THRESHOLD) / (100 - THRESHOLD)) * 100)
}

function useHealthScore(system: SystemRecord, chartData: ChartData) {
	return useMemo(() => {
		if (system.status !== SystemStatus.Up) {
			return null
		}
		const last = chartData.systemStats.at(-1)?.stats
		if (!last) {
			return null
		}
		const swapPercent = last.s > 0 ? (last.su / last.s) * 100 : 0
		const deductions =
			deduction(last.cpu) * WEIGHTS.cpu +
			deduction(last.mp) * WEIGHTS.mem +
			deduction(last.dp) * WEIGHTS.disk +
			deduction(swapPercent) * WEIGHTS.swap
		const score = Math.round(Math.max(0, 100 - deductions))
		return { score, cpu: last.cpu, mem: last.mp, disk: last.dp, swap: swapPercent }
	}, [system.status, chartData.systemStats])
}

export default function HealthScore({ system, chartData }: { system: SystemRecord; chartData: ChartData }) {
	const { t } = useLingui()
	const health = useHealthScore(system, chartData)

	if (!health) {
		return null
	}

	const { score, cpu, mem, disk, swap } = health

	return (
		<Card>
			<Tooltip delayDuration={100}>
				<TooltipTrigger asChild>
					<div className="flex items-center gap-3 px-4 sm:px-6 py-3">
						<ActivityIcon
							className={cn("size-5 shrink-0", {
								"text-green-500": score >= 80,
								"text-yellow-500": score >= 50 && score < 80,
								"text-red-500": score < 50,
							})}
						/>
						<div className="min-w-0">
							<div className="text-sm text-muted-foreground">
								<Trans>Health Score</Trans>
							</div>
							<div className="text-xl font-semibold tabular-nums">{score}</div>
						</div>
					</div>
				</TooltipTrigger>
				<TooltipContent>
					<div className="grid gap-0.5 text-xs">
						<span>
							{t`CPU`}: {cpu.toFixed(0)}%
						</span>
						<span>
							{t`Memory`}: {mem.toFixed(0)}%
						</span>
						<span>
							{t`Disk`}: {disk.toFixed(0)}%
						</span>
						{swap > 0 && (
							<span>
								{t`Swap`}: {swap.toFixed(0)}%
							</span>
						)}
					</div>
				</TooltipContent>
			</Tooltip>
		</Card>
	)
}
