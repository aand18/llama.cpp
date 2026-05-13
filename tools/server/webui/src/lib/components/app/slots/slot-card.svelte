<script lang="ts">
	import { cn } from '$lib/components/ui/utils';
	import { Badge } from '$lib/components/ui/badge';
	import { ChevronDown, ChevronRight, Star } from '@lucide/svelte';
	import { prettyText, escapeHtml } from '$lib/utils/strip-special-tokens';

	interface Props {
		slot: ApiSlotData;
		tokensPerSecond: number;
		prettyMode: boolean;
		isProtected?: boolean | null;
		onStar?: () => void;
	}

	let { slot, tokensPerSecond, prettyMode, isProtected = null, onStar = undefined }: Props = $props();

	let promptOpen = $state(false);
	let generatedOpen = $state(true);
	let cardRef = $state<HTMLDivElement | null>(null);
	let scrollRef = $state<HTMLDivElement | null>(null);
	let userAtBottom = true;

	let ntok = $derived(slot.next_token?.[0]);
	let hasTask = $derived(slot.id_task !== undefined && slot.id_task > 0);
	let decoded = $derived(ntok?.n_decoded ?? 0);
	let remaining = $derived(ntok?.n_remain ?? 0);
	let total = $derived(decoded + remaining);
	let progress = $derived(total > 0 ? Math.log10(1 + 9 * (decoded / total)) * 100 : 0);

	let p = $derived(slot.params);
	let samplersStr = $derived(p?.samplers?.join(', ') ?? '');
	let hasDebugData = $derived(!!slot.prompt || !!slot.generated);

	// Track scroll position: only auto-scroll when user is near bottom
	function onScroll() {
		if (!scrollRef) return;
		userAtBottom = scrollRef.scrollHeight - scrollRef.scrollTop - scrollRef.clientHeight < 80;
	}

	// Auto-scroll smoothly when new text arrives, only if user is at bottom
	let genLen = $derived(slot.generated?.length ?? 0);
	$effect(() => {
		if (!generatedOpen || !scrollRef) return;
		// genLen is already derived above — effect re-runs when generated text grows

		if (userAtBottom) {
			// Double rAF to wait for DOM to settle after reactive update
			requestAnimationFrame(() => {
				requestAnimationFrame(() => {
					if (scrollRef) {
						scrollRef.scrollTo({ top: scrollRef.scrollHeight, behavior: 'smooth' });
					}
				});
			});
		}
	});

	// Scroll card into view when generated section expands
	$effect(() => {
		if (generatedOpen && cardRef) {
			requestAnimationFrame(() => {
				cardRef?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
			});
		}
	});
</script>

<div
	bind:this={cardRef}
	class={cn(
		'flex flex-col gap-3 rounded-xl border bg-card p-4 text-card-foreground shadow-sm transition-colors',
		slot.is_processing ? 'border-primary/30' : 'border-border/30'
	)}
>
	<div class="flex flex-wrap items-start justify-between gap-1">
		<div class="flex flex-wrap items-center gap-1.5">
			<div class={cn('mt-0.5 h-2 w-2 shrink-0 rounded-full', slot.is_processing ? 'bg-green-500' : 'bg-muted-foreground/40')}></div>
			<span class="font-semibold">Slot {slot.id}</span>
			{#if hasTask}
				<Badge variant="secondary" class="text-[10px]">T:{slot.id_task}</Badge>
			{/if}
			{#if slot.speculative}
				<Badge variant="outline" class="text-[10px]">speculative</Badge>
			{/if}
			{#if !hasDebugData}
				<Badge variant="outline" class="border-yellow-300 text-[10px] text-yellow-600 dark:text-yellow-400">
					metrics-only
				</Badge>
			{/if}
		</div>

		<div class="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
			{#if isProtected !== null}
				<button
					onclick={onStar}
					class="rounded p-0.5 transition-colors hover:bg-accent"
					title={isProtected ? 'Unprotect from deletion' : 'Protect from deletion'}
				>
					<Star class={cn('size-3', isProtected === true && 'fill-yellow-500 text-yellow-500')} />
				</button>
			{/if}
			<span>ctx:{slot.n_ctx?.toLocaleString()}</span>
			{#if tokensPerSecond > 0}
				<span class="text-green-600 dark:text-green-400">{tokensPerSecond.toFixed(1)} t/s</span>
			{/if}
		</div>
	</div>

	{#if hasTask}
		<!-- Token Progress -->
		<div class="flex flex-col gap-1">
			<div class="flex justify-between text-xs text-muted-foreground">
				<span>gen:{decoded} rem:{remaining}</span>
				<span>t:{total}</span>
			</div>

			<div class="h-1.5 w-full overflow-hidden rounded-full bg-muted">
				<div
					class={cn('h-full rounded-full transition-all duration-500', slot.is_processing ? 'bg-green-500' : 'bg-muted-foreground/30')}
					style="width: {progress}%"
				></div>
			</div>
		</div>

		<!-- Params Summary -->
		{#if p}
			<div class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
				<span title="Temperature">temp:{p.temperature?.toFixed(2)}</span>
				<span title="Top-K">k:{p.top_k}</span>
				<span title="Top-P">p:{p.top_p?.toFixed(2)}</span>
				<span title="Repeat Penalty">rp:{p.repeat_penalty?.toFixed(2)}</span>
				<span title="Max Tokens">max:{p.max_tokens ?? p.n_predict}</span>
				{#if p.grammar}
					<span title="Grammar active" class="text-yellow-600 dark:text-yellow-400">grammar</span>
				{/if}
				{#if p.dry_multiplier && p.dry_multiplier > 0}
					<span title="DRY active">dry:{p.dry_multiplier}</span>
				{/if}
			</div>

			<!-- Samplers -->
			<div class="flex flex-wrap gap-1 text-[10px] text-muted-foreground">
				{samplersStr}
			</div>
		{/if}
	{:else}
		<div class="py-1 text-xs text-muted-foreground">(idle, no active task)</div>
	{/if}

	<!-- Prompt Section -->
	{#if hasDebugData}
		{#if promptOpen}
			<div class="flex flex-col gap-1">
				<button
					onclick={() => (promptOpen = false)}
					class="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
				>
					<ChevronDown class="size-3" />
					Prompt ({slot.prompt?.length?.toLocaleString()} chars)
				</button>

				<pre class="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-md bg-muted/50 p-2 text-xs leading-relaxed" style="scrollbar-gutter:stable">{@html prettyMode ? escapeHtml(prettyText(slot.prompt ?? '')) : escapeHtml(slot.prompt ?? '')}</pre>
			</div>
		{:else}
			<button
				onclick={() => (promptOpen = true)}
				class="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
			>
				<ChevronRight class="size-3" />
				Prompt ({slot.prompt?.length?.toLocaleString()} chars)
			</button>
		{/if}

		<!-- Generated Section -->
		<div class="flex flex-col gap-1">
			<button
				onclick={() => (generatedOpen = !generatedOpen)}
				class="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
			>
				{#if generatedOpen}
					<ChevronDown class="size-3" />
				{:else}
					<ChevronRight class="size-3" />
				{/if}
				Generated ({slot.generated?.length?.toLocaleString()} chars)
			</button>

			{#if generatedOpen}
				<div bind:this={scrollRef} onscroll={onScroll} class="max-h-[60vh] overflow-auto rounded-md border border-border/20 bg-code-background" style="scrollbar-gutter:stable">
					<pre class="whitespace-pre-wrap break-all p-3 text-xs leading-relaxed text-code-foreground">{@html prettyMode ? escapeHtml(prettyText(slot.generated ?? '')) : escapeHtml(slot.generated ?? '')}</pre>
				</div>
			{/if}
		</div>
	{/if}
</div>
