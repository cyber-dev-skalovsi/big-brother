import { useId } from "react"

export function Logo({ className }: { className?: string }) {
	const id = useId()

	return (
		<span className={`inline-flex items-center gap-2 font-semibold tracking-tight select-none ${className ?? ""}`}>
			<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" className="h-[1.4em] w-[1.4em] shrink-0">
				<defs>
					<linearGradient id={id} x1="0%" y1="0%" x2="100%" y2="100%">
						<stop offset="0%" style={{ stopColor: "#E8895E" }} />
						<stop offset="100%" style={{ stopColor: "#C5603E" }} />
					</linearGradient>
				</defs>
				<circle
					cx="32"
					cy="32"
					r="30"
					fill={`url(#${id})`}
					className="duration-300 group-hover:scale-105 origin-center transition-transform"
				/>
				<path
					fill="#FBEDE6"
					d="M32 18c10 0 17.6 6.7 20.5 13.2.4.9.4 1.7 0 2.6C49.6 40.3 42 47 32 47S14.4 40.3 11.5 33.8a2.9 2.9 0 0 1 0-2.6C14.4 24.7 22 18 32 18Zm0 5c-6 0-11 4-11 9s5 9 11 9 11-4 11-9-5-9-11-9Z"
				/>
				<circle cx="32" cy="32" r="6" fill="#C5603E" />
			</svg>
			<span className="leading-none">
				<span className="text-foreground">Big</span> <span style={{ color: "#C5603E" }}>Brother</span>
			</span>
		</span>
	)
}
