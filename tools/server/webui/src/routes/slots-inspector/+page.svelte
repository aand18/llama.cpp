<script lang="ts">
	import { onMount } from 'svelte';
	import { Clock, History as HistoryIcon, Loader2, Pause, Play, RefreshCw } from '@lucide/svelte';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { SlotCard, HistoryOverlay } from '$lib/components/app';
	import {
		slotsStore,
		slots,
		slotsError,
		slotsLoading,
		slotsDebugMode,
		slotsHistoryCount,
		slotsAnyProcessing,
		slotProtected,
		slotToggleProtected
	} from '$lib/stores/slots.svelte';

	let historyOpen = $state(false);
	let prettyMode = $state(true);
	let paused = $state(false);
	let pollInterval = $state(2000);
	let tps = $state<Record<number, number>>({});
	let prevDecoded = new Map<number, number>();
	let prevTime = new Map<number, number>();
	let protectedMap = $state(new Map<number, boolean>());

	$effect(() => {
		const currentSlots = slots();
		for (const s of currentSlots) {
			const taskId = s.id_task;
			if (taskId && taskId > 0) {
				const p = slotProtected(taskId);
				if (p !== null) {
					protectedMap.set(taskId, p);
				}
			}
		}
	});

	onMount(() => {
		slotsStore.startPolling();

		return () => {
			slotsStore.stopPolling();
		};
	});

	function togglePause() {
		paused = !paused;
		if (paused) {
			slotsStore.stopPolling();
			prevDecoded.clear();
			prevTime.clear();
		} else {
			slotsStore.startPolling();
		}
	}

	// Track tokens/sec from poll deltas, normalized by elapsed time
	$effect(() => {
		const currentSlots = slots();
		const next: Record<number, number> = {};

		for (const slot of currentSlots) {
			const curr = slot.next_token?.[0]?.n_decoded ?? 0;
			const now = Date.now();

			if (slot.is_processing) {
				const prev = prevDecoded.get(slot.id) ?? curr;
				const prevT = prevTime.get(slot.id) ?? now;
				const elapsed = (now - prevT) / 1000;
				const speed = elapsed > 0 ? (curr - prev) / elapsed : 0;
				next[slot.id] = speed;
				prevDecoded.set(slot.id, curr);
				prevTime.set(slot.id, now);
			} else {
				next[slot.id] = 0;
				prevDecoded.set(slot.id, 0);
				prevTime.set(slot.id, 0);
			}
		}

		tps = next;
	});

	function getTokenSpeed(slotId: number): number {
		return tps[slotId] ?? 0;
	}
</script>

<svelte:head>
	<title>Slots Debug - llama.cpp</title>
</svelte:head>

<div class="mx-auto flex w-full max-w-5xl flex-col gap-4 overflow-x-hidden px-4 py-6 min-h-[80dvh]">
	<!-- Header -->
	<div class="flex flex-wrap items-start justify-between gap-3">
		<div class="flex flex-wrap items-center gap-2">
			<h1 class="text-xl font-bold tracking-tight">Slots</h1>

			{#if slotsDebugMode()}
				<Badge variant="outline" class="border-yellow-300 text-[10px] text-yellow-600 dark:text-yellow-400">debug</Badge>
			{:else}
				<Badge variant="outline" class="text-[10px] text-muted-foreground">metrics-only</Badge>
			{/if}

			{#if slotsAnyProcessing()}
			<span class="inline-flex items-center gap-1 text-xs text-muted-foreground">
				<span class="inline-block h-2 w-2 animate-pulse rounded-full bg-green-500"></span>
				processing
			</span>
			{/if}
		</div>

		<div class="flex flex-wrap items-center gap-2">
			<!-- Pretty/Raw toggle -->
			<Button
				variant={prettyMode ? 'default' : 'outline'}
				size="sm"
				onclick={() => (prettyMode = !prettyMode)}
				class="text-xs px-2.5"
			>
				{prettyMode ? 'pretty' : 'raw'}
			</Button>

			<!-- Pause/Resume -->
			<Button variant="outline" size="icon" onclick={togglePause} title={paused ? 'Resume polling' : 'Pause polling'}>
				{#if paused}
					<Play class="size-4" />
				{:else}
					<Pause class="size-4" />
				{/if}
			</Button>

			<!-- Refresh button -->
			<Button variant="outline" size="icon" onclick={() => slotsStore.fetch()} title="Refresh now">
				<RefreshCw class="size-4" />
			</Button>

			<!-- History button -->
			<Button
				variant="outline"
				size="sm"
				onclick={() => (historyOpen = true)}
				class="gap-1.5 text-xs px-3"
			>
				<HistoryIcon class="size-4" />
				History
				{#if slotsHistoryCount() > 0}
					<Badge variant="secondary" class="text-[10px]">{slotsHistoryCount()}</Badge>
				{/if}
			</Button>
		</div>
	</div>

	<!-- Error -->
	{#if slotsError()}
		<div class="rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
			{slotsError()}

			<p class="mt-1 text-xs text-muted-foreground">
				Make sure the server has the slots endpoint enabled (<code>--slots</code> flag).
				Set <code>LLAMA_SERVER_SLOTS_DEBUG=1</code> to see prompt & generated text.
			</p>
		</div>
	{/if}

	<!-- Debug mode hint -->
	{#if !slotsDebugMode() && !slotsError()}
		<div class="rounded-md border border-yellow-300/30 bg-yellow-50 p-3 text-xs text-yellow-800 dark:border-yellow-600/30 dark:bg-yellow-900/20 dark:text-yellow-200">
			Prompt and generated text not available. Set <code class="font-semibold">LLAMA_SERVER_SLOTS_DEBUG=1</code> on the server and restart to see full slot content, useful for debugging looping answers.
		</div>
	{/if}

	<!-- Slot Cards -->
	<div class="flex flex-col gap-3">
		{#each slots() as slot (slot.id)}
			<SlotCard
				{slot}
				tokensPerSecond={getTokenSpeed(slot.id)}
				{prettyMode}
				isProtected={slot.id_task ? protectedMap.get(slot.id_task) ?? null : null}
				onStar={slot.id_task ? () => slotToggleProtected(slot.id_task!) : undefined}
			/>
		{/each}
	</div>

	<!-- Spacer to push footer to bottom -->
	<div class="grow"></div>

	<!-- Empty State -->
	{#if !slotsLoading() && slots().length === 0 && !slotsError()}
		<div class="flex flex-col items-center justify-center py-16 text-sm text-muted-foreground">
			No slots found. The server may have the slots endpoint disabled.
		</div>
	{/if}

	<!-- Footer with timing info -->
	<div class="flex items-center justify-between text-xs text-muted-foreground">
		<div class="flex items-center gap-2">
			<Clock class="size-3" />
			<span>Polling every {pollInterval / 1000}s</span>
			{#if paused}
				<span class="text-yellow-600 dark:text-yellow-400">(paused)</span>
			{/if}
			{#if slotsLoading()}
				<Loader2 class="size-3 animate-spin" />
			{/if}
		</div>

		<span>{slots().length} slot{slots().length !== 1 ? 's' : ''}</span>
	</div>
</div>

<!-- History Overlay -->
<HistoryOverlay open={historyOpen} onclose={() => (historyOpen = false)} />
