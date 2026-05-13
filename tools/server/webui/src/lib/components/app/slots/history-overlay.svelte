<script module lang="ts">
	let _savedListScrollTop = 0;
</script>

<script lang="ts">
	import { X, History as HistoryIcon, Star, Trash2, ChevronDown, ChevronRight } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { DialogConfirmation } from '$lib/components/app';
	import { cn } from '$lib/components/ui/utils';
	import { SlotsHistoryService, type SlotSnapshot, type SlotSnapshotMeta } from '$lib/services/slots-history.service';
	import { prettyText, escapeHtml } from '$lib/utils/strip-special-tokens';
	import HistoryEntry from './history-entry.svelte';

	interface Props {
		open: boolean;
		onclose: () => void;
	}

	let { open, onclose }: Props = $props();

	let entries = $state<SlotSnapshotMeta[]>([]);
	let loading = $state(false);
	let error = $state<string | null>(null);
	let storageEstimate = $state('');
	let selectedId = $state<number | undefined>();
	let selectedDetail = $state<SlotSnapshot | null>(null);
	let detailLoading = $state(false);
	let itemSize = $state('');
	let rawMode = $state(false);
	let starredOnly = $state(false);

	let filteredEntries = $derived(starredOnly ? entries.filter((e) => e.protected === true) : entries);

	let generatedScrollRef = $state<HTMLDivElement | null>(null);
	let promptScrollRef = $state<HTMLPreElement | null>(null);
	let listScrollRef = $state<HTMLDivElement | null>(null);

	let expandPrefs = $state({ prompt: false, genPrompt: false, generated: true });
	let showClearDialog = $state(false);

	let savedListScrollTop = $state(_savedListScrollTop);

	function setExpandPref(key: 'prompt' | 'genPrompt' | 'generated', val: boolean) {
		expandPrefs[key] = val;
	}

	async function load() {
		loading = true;
		error = null;

		try {
			entries = await SlotsHistoryService.list();
			storageEstimate = await SlotsHistoryService.estimateStorage();

			if (entries.length > 0 && !selectedId) {
				selectEntry(entries[0].id!);
			}
		} catch (e) {
			error = e instanceof Error ? e.message : 'Failed to load history';
			entries = [];
		} finally {
			loading = false;
		}
	}

	async function selectEntry(id: number) {
		if (selectedId === id) return;
		const isInitial = !selectedDetail;

		if (isInitial) {
			detailLoading = true;
		}
		selectedId = id;
		itemSize = '';

		try {
			const [detail, size] = await Promise.all([
				SlotsHistoryService.getDetail(id),
				SlotsHistoryService.estimateItemSize(id)
			]);
			if (selectedId === id) {
				selectedDetail = detail ?? null;
				itemSize = size;
			}
		} catch (e) {
			if (selectedId === id) {
				selectedDetail = null;
				itemSize = '';
			}
		} finally {
			if (selectedId === id) {
				detailLoading = false;
			}
		}

		// Scroll selected entry into view
		requestAnimationFrame(() => {
			const el = document.querySelector(`[data-history-id="${id}"]`);
			if (el && listScrollRef) {
				const listRect = listScrollRef.getBoundingClientRect();
				const elRect = el.getBoundingClientRect();
				if (elRect.top < listRect.top || elRect.bottom > listRect.bottom) {
					el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
				}
			}
		});
	}

	async function toggleProtected(id: number, current: boolean | undefined) {
		const next = !current;
		await SlotsHistoryService.setProtected(id, next);

		if (selectedDetail && selectedDetail.id === id) {
			selectedDetail.protected = next;
		}

		const entry = entries.find((e) => e.id === id);
		if (entry) {
			entry.protected = next;
		}
	}

	async function clearHistory() {
		showClearDialog = false;
		await SlotsHistoryService.clear();
		entries = [];
		selectedId = undefined;
		selectedDetail = null;
		storageEstimate = '';
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') onclose();
	}

	function onListScroll() {
		if (listScrollRef) {
			_savedListScrollTop = listScrollRef.scrollTop;
			savedListScrollTop = listScrollRef.scrollTop;
		}
	}

	$effect(() => {
		if (open) {
			load();
		}
	});

	// Restore list scroll position after entries render
	$effect(() => {
		if (listScrollRef && savedListScrollTop > 0) {
			listScrollRef.scrollTop = savedListScrollTop;
		}
	});

	// Auto-scroll generated text to bottom when detail loads or generated section opens
	$effect(() => {
		if (expandPrefs.generated && generatedScrollRef) {
			requestAnimationFrame(() => {
				requestAnimationFrame(() => {
					generatedScrollRef?.scrollTo({ top: generatedScrollRef.scrollHeight, behavior: 'smooth' });
				});
			});
		}
	});

	// Reset scroll positions when switching entries
	$effect(() => {
		if (selectedDetail) {
			requestAnimationFrame(() => {
				if (generatedScrollRef) generatedScrollRef.scrollTop = 0;
				if (promptScrollRef) promptScrollRef.scrollTop = 0;
			});
		}
	});
</script>

<svelte:window onkeydown={handleKeydown} />

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- svelte-ignore a11y_interactive_supports_focus -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
	role="dialog"
	aria-modal="true"
	tabindex="-1"
	class="fixed inset-0 z-[1000000] flex items-start justify-center bg-black/50 pt-0 backdrop-blur-sm sm:pt-4"
	class:hidden={!open}
	onclick={(e) => {
		if (e.target === e.currentTarget) onclose();
	}}
>
	<div
		class="flex h-dvh w-full max-w-5xl flex-col overflow-hidden bg-background sm:mb-4 sm:h-[90dvh] sm:rounded-xl sm:shadow-xl"
	>
		<!-- Header -->
		<div class="flex shrink-0 items-center justify-between border-b px-3 py-2 sm:px-4 sm:py-3">
			<div class="flex items-center gap-2">
				<HistoryIcon class="size-4" />
				<span class="font-semibold">Slot History</span>
				<Badge variant="secondary" class="text-[10px]">{filteredEntries.length}</Badge>
			</div>

			<div class="flex items-center gap-1 sm:gap-2">
				<button
					onclick={() => (rawMode = !rawMode)}
					class="rounded-md px-2 py-1 text-xs transition-colors hover:bg-accent"
					class:bg-accent={rawMode}
				>
					raw
				</button>

				<Button variant="ghost" size="icon-sm" onclick={onclose}>
					<X class="size-4" />
				</Button>
			</div>
		</div>

		<!-- Body: stacked on mobile, side-by-side on desktop -->
		<div class="flex min-h-0 flex-1 flex-col sm:flex-row">
			<!-- Left panel: entries list -->
			<div class="flex shrink-0 flex-col border-b sm:w-72 sm:border-b-0 sm:border-r max-h-[40dvh] sm:max-h-none">
				<!-- Star filter header -->
				<div class="flex items-center justify-between border-b border-border/10 px-3 py-1.5">
					<button
						onclick={() => (starredOnly = !starredOnly)}
						class="flex items-center gap-1.5 rounded-md px-2 py-1 text-xs transition-colors hover:bg-accent"
						class:bg-accent={starredOnly}
						title={starredOnly ? 'Show all' : 'Show starred only'}
					>
						<Star class={cn('size-3.5', starredOnly && 'fill-yellow-500 text-yellow-500')} />
						{starredOnly ? 'Starred' : 'All'}
					</button>

					<span class="text-[10px] text-muted-foreground/60">{filteredEntries.length} entries</span>
				</div>

				<!-- Scrollable list -->
				<div
					bind:this={listScrollRef}
					onscroll={onListScroll}
					class="flex-1 overflow-y-auto p-2"
				>
					{#if loading}
						<div class="flex items-center justify-center py-8 text-sm text-muted-foreground">Loading...</div>
					{:else if error}
						<div class="p-3 text-sm text-destructive">{error}</div>
					{:else if filteredEntries.length === 0}
						<div class="flex items-center justify-center py-8 text-sm text-muted-foreground">{starredOnly ? 'No starred snapshots' : 'No snapshots saved yet'}</div>
					{:else}
						<div class="flex flex-col gap-1">
							{#each filteredEntries as entry (entry.id)}
								<button
									onclick={() => selectEntry(entry.id!)}
									class="w-full rounded-md text-left"
									class:bg-accent={selectedId === entry.id}
									data-history-id={entry.id}
								>
									<HistoryEntry
										snapshot={entry}
										onToggleProtected={toggleProtected}
									/>
								</button>
							{/each}
						</div>
					{/if}
				</div>

				<!-- Footer: MB + Clear -->
				<div class="flex items-center justify-between border-t border-border/10 px-3 py-1.5 text-[10px] text-muted-foreground/60">
					<span>{storageEstimate || '0 B'}</span>
					<button
						onclick={() => (showClearDialog = true)}
						class="flex items-center gap-1 rounded px-2 py-0.5 transition-colors hover:bg-accent hover:text-destructive"
					>
						<Trash2 class="size-3" />
						Clear data
					</button>
				</div>
			</div>

			<!-- Right panel: detail view -->
			<div class="flex min-h-0 flex-1 flex-col overflow-hidden p-3 sm:p-4">
				{#if detailLoading && !selectedDetail}
					<div class="flex items-center justify-center py-16 text-sm text-muted-foreground">Loading details...</div>
				{:else if selectedDetail}
					{@const d = selectedDetail}
					{@const rt = d.started_at ? d.timestamp - d.started_at : 0}
					{@const tps = rt > 0 ? (d.n_decoded / (rt / 1000)).toFixed(1) + ' t/s' : ''}
					<div class="flex flex-col gap-3 overflow-y-auto">
						<!-- Hierarchy: Tokens / TPS / Runtime / Timestamp -->
						<div class="flex flex-wrap items-center gap-2">
							<span class="text-base font-semibold text-foreground">Tokens {d.n_decoded.toLocaleString()}</span>
							{#if tps}
								<span class="font-medium text-green-600 dark:text-green-400">{tps}</span>
							{/if}
							{#if rt > 0}
								{@const rtStr = rt < 1000 ? `${rt}ms` : rt < 60000 ? `${(rt / 1000).toFixed(1)}s` : `${Math.floor(rt / 60000)}m ${Math.floor((rt % 60000) / 1000)}s`}
								<span class="text-muted-foreground">{rtStr}</span>
							{/if}
							<div class="ml-auto flex items-center gap-1.5 text-muted-foreground/60">
								<span class="text-xs">{new Date(d.timestamp).toLocaleTimeString()}</span>
								<button
									onclick={() => toggleProtected(d.id!, d.protected)}
									class="rounded p-0.5 transition-colors hover:bg-accent"
									title={d.protected ? 'Unprotect from deletion' : 'Protect from deletion'}
								>
									<Star class={cn('size-3.5', d.protected === true && 'fill-yellow-500 text-yellow-500')} />
								</button>
							</div>
						</div>

						<!-- Meta pills (same style as list) -->
						<div class="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground/60">
							<Badge variant="secondary" class="text-[10px]">Slot {d.slotId}</Badge>
							<Badge variant="outline" class="text-[10px]">T:{d.taskId}</Badge>
							<span>rem:{d.n_remain}</span>
							<span>ctx:{d.n_ctx}</span>
							<span class="text-muted-foreground/30">{new Date(d.timestamp).toLocaleDateString()}</span>
							{#if itemSize}
								<span class="text-muted-foreground/30">{itemSize}</span>
							{/if}
						</div>

						<!-- Params -->
						<div class="flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted-foreground/60">
							<span>t:{d.temperature.toFixed(2)}</span>
							<span>k:{d.top_k}</span>
							<span>p:{d.top_p.toFixed(2)}</span>
							<span>rp:{d.repeat_penalty.toFixed(2)}</span>
						</div>

						<!-- Generation Prompt (collapsible) -->
						{#if d.generation_prompt}
							<div class="flex flex-col gap-1">
								<button
									onclick={() => setExpandPref('genPrompt', !expandPrefs.genPrompt)}
									class="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
								>
									{#if expandPrefs.genPrompt}
										<ChevronDown class="size-3" />
									{:else}
										<ChevronRight class="size-3" />
									{/if}
									Generation Prompt
								</button>

								{#if expandPrefs.genPrompt}
									<pre class="max-h-16 overflow-auto whitespace-pre-wrap break-all rounded-md bg-muted/50 p-2 text-xs">{@html rawMode ? escapeHtml(d.generation_prompt) : escapeHtml(prettyText(d.generation_prompt))}</pre>
								{/if}
							</div>
						{/if}

						<!-- Prompt (collapsible) -->
						{#if d.prompt}
							<div class="flex flex-col gap-1">
								<button
									onclick={() => setExpandPref('prompt', !expandPrefs.prompt)}
									class="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
								>
									{#if expandPrefs.prompt}
										<ChevronDown class="size-3" />
									{:else}
										<ChevronRight class="size-3" />
									{/if}
									Prompt ({d.prompt.length.toLocaleString()} chars)
								</button>

								{#if expandPrefs.prompt}
									<pre bind:this={promptScrollRef} class="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-md bg-muted/50 p-2 text-xs leading-relaxed">{@html rawMode ? escapeHtml(d.prompt) : escapeHtml(prettyText(d.prompt))}</pre>
								{/if}
							</div>
						{/if}

						<!-- Generated (collapsible, default open) -->
						<div class="flex flex-col gap-1">
							<button
								onclick={() => setExpandPref('generated', !expandPrefs.generated)}
								class="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
							>
								{#if expandPrefs.generated}
									<ChevronDown class="size-3" />
								{:else}
									<ChevronRight class="size-3" />
								{/if}
								Generated ({d.generated.length.toLocaleString()} chars)
							</button>

							{#if expandPrefs.generated}
								<div
									bind:this={generatedScrollRef}
									class="overflow-auto rounded-md border border-border/20 bg-code-background"
									style="scrollbar-gutter:stable"
								>
									<pre class="max-h-[50dvh] whitespace-pre-wrap break-all p-3 text-xs leading-relaxed text-code-foreground">{@html rawMode ? escapeHtml(d.generated) : escapeHtml(prettyText(d.generated))}</pre>
								</div>
							{/if}
						</div>
					</div>
				{:else if selectedId}
					<div class="flex items-center justify-center py-16 text-sm text-muted-foreground">Failed to load details</div>
				{:else}
					<div class="flex items-center justify-center py-16 text-sm text-muted-foreground">Select an entry to view details</div>
				{/if}
			</div>
		</div>
	</div>
</div>

<DialogConfirmation
	bind:open={showClearDialog}
	title="Clear History"
	description="Delete all {entries.length} slot history snapshots? Starred entries will also be removed."
	confirmText="Clear All"
	cancelText="Cancel"
	variant="destructive"
	icon={Trash2}
	onConfirm={clearHistory}
/>
