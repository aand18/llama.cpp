<script lang="ts">
	import { cn } from '$lib/components/ui/utils';
	import { Star } from '@lucide/svelte';
	import { Badge } from '$lib/components/ui/badge';
	import type { SlotSnapshotMeta } from '$lib/services/slots-history.service';

	interface Props {
		snapshot: SlotSnapshotMeta;
		onToggleProtected?: (id: number, current: boolean | undefined) => void;
	}

	let { snapshot, onToggleProtected }: Props = $props();

	let time = $derived(new Date(snapshot.timestamp).toLocaleTimeString());
	let saved = $derived(snapshot.protected === true);

	function formatRuntime(ms: number): string {
		if (ms <= 0) return '';
		if (ms < 1000) return `${ms}ms`;
		if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
		return `${Math.floor(ms / 60000)}m ${Math.floor((ms % 60000) / 1000)}s`;
	}

	let runtime = $derived(snapshot.started_at ? snapshot.timestamp - snapshot.started_at : 0);
	let runtimeStr = $derived(formatRuntime(runtime));
	let tps = $derived(runtime > 0 ? (snapshot.n_decoded / (runtime / 1000)).toFixed(1) : '');

	function handleStarClick(e: MouseEvent) {
		e.stopPropagation();
		if (onToggleProtected && snapshot.id) {
			onToggleProtected(snapshot.id, snapshot.protected);
		}
	}
</script>

<div class="group flex cursor-pointer flex-col gap-1 rounded-md border border-border/20 p-2.5 text-xs transition-colors hover:bg-accent/50">
	<div class="flex items-center gap-2">
		<span class="font-semibold text-foreground">Tokens {snapshot.n_decoded}</span>
		{#if tps}
			<span class="font-medium text-green-600 dark:text-green-400">{tps} t/s</span>
		{/if}

		<div class="ml-auto flex items-center gap-1">
			{#if snapshot.generation_prompt}
				<span class="truncate max-w-24 text-muted-foreground" title={snapshot.generation_prompt}>{snapshot.generation_prompt.replace(/<[^>]*>/g, '').trim().slice(0, 30)}</span>
			{/if}
			<button
				onclick={handleStarClick}
				class="rounded p-0.5 opacity-0 transition-opacity hover:bg-accent group-hover:opacity-100"
				class:opacity-100={saved}
				title={saved ? 'Unprotect' : 'Protect'}
			>
				<Star
					class={cn('size-3', saved && 'fill-yellow-500 text-yellow-500')}
				/>
			</button>
		</div>
	</div>

	<div class="flex items-center gap-1.5 text-muted-foreground">
		<span class="text-muted-foreground/70">{time}</span>
		<Badge variant="secondary" class="text-[10px]">Slot {snapshot.slotId}</Badge>
		{#if snapshot.taskId}
			<Badge variant="outline" class="text-[10px]">T:{snapshot.taskId}</Badge>
		{/if}
		{#if runtimeStr}
			<span class="text-muted-foreground/50">{runtimeStr}</span>
		{/if}
		<span class="text-muted-foreground/50">rem:{snapshot.n_remain}</span>
		<span class="text-muted-foreground/50">ctx:{snapshot.n_ctx}</span>
	</div>
</div>
