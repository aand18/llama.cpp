import { SlotsService } from '$lib/services/slots.service';
import { SlotsHistoryService } from '$lib/services/slots-history.service';
import type { SlotSnapshot } from '$lib/services/slots-history.service';

class SlotsStore {
	slots = $state<ApiSlotData[]>([]);
	error = $state<string | null>(null);
	loading = $state(false);
	debugMode = $state(false);
	historyCount = $state(0);

	private prevDecoded = new Map<number, number>();
	private lastRecordedDecoded = new Map<number, number>();
	private startedAt = new Map<number, number>();
	private lastTaskId = new Map<number, number>();
	private snapshotInfo = $state<Record<number, { id: number; protected: boolean }>>({});

	get anyProcessing(): boolean {
		return this.slots.some((s) => s.is_processing);
	}

	async fetch(): Promise<void> {
		this.loading = true;
		this.error = null;

		try {
			const data = await SlotsService.list();

			this.debugMode = data.some((s) => s.prompt !== undefined);

			// Merge new data into existing slots to avoid full re-render
			const usedIds = new Set<number>();

			for (const newSlot of data) {
				usedIds.add(newSlot.id);
				const existing = this.slots.find((s) => s.id === newSlot.id);

				if (existing) {
					existing.is_processing = newSlot.is_processing;
					existing.id_task = newSlot.id_task;
					existing.speculative = newSlot.speculative;
					existing.n_ctx = newSlot.n_ctx;
					existing.prompt = newSlot.prompt;
					existing.generated = newSlot.generated;
					existing.params = newSlot.params as typeof existing.params;

					if (newSlot.next_token && newSlot.next_token.length > 0) {
						if (existing.next_token && existing.next_token.length > 0) {
							for (const key of Object.keys(newSlot.next_token[0])) {
								(existing.next_token[0] as Record<string, unknown>)[key] =
									(newSlot.next_token[0] as Record<string, unknown>)[key];
							}
						} else {
							existing.next_token = newSlot.next_token;
						}
					}
				} else {
					this.slots.push(newSlot);
				}
			}

			// Remove stale slots
			for (let i = this.slots.length - 1; i >= 0; i--) {
				if (!usedIds.has(this.slots[i].id)) {
					this.slots.splice(i, 1);
				}
			}

			for (const slot of this.slots) {
				const nt = slot.next_token?.[0];
				const currDecoded = nt?.n_decoded ?? 0;

				if (nt && slot.is_processing) {
					const prevDecoded = this.prevDecoded.get(slot.id) ?? currDecoded;
					this.prevDecoded.set(slot.id, currDecoded);

					const taskId = slot.id_task ?? 0;
					if (taskId > 0) {
						this.lastTaskId.set(slot.id, taskId);
					}
					if (!this.startedAt.has(taskId)) {
						this.startedAt.set(taskId, Date.now());
					}

					// Only persist snapshot when decoded count advances
					if (currDecoded !== this.lastRecordedDecoded.get(slot.id)) {
						this.lastRecordedDecoded.set(slot.id, currDecoded);

						const p = slot.params;
						const snapshot: SlotSnapshot = {
							slotId: slot.id,
							taskId,
							timestamp: Date.now(),
							started_at: this.startedAt.get(taskId) ?? Date.now(),
							n_decoded: currDecoded,
							n_remain: nt?.n_remain ?? 0,
							n_ctx: slot.n_ctx,
							speculative: slot.speculative,
							prompt: String(slot.prompt ?? ''),
							generated: String(slot.generated ?? ''),
							generation_prompt: String(p?.generation_prompt ?? ''),
							temperature: Number(p?.temperature ?? 0),
							top_k: Number(p?.top_k ?? 0),
							top_p: Number(p?.top_p ?? 0),
							repeat_penalty: Number(p?.repeat_penalty ?? 0),
							samplers: [...(p?.samplers ?? [])],
							debug_mode: this.debugMode,
							protected: false
						};

						await SlotsHistoryService.add(snapshot);
					}

					if (taskId > 0) {
						const meta = await SlotsHistoryService.findLatestMeta(taskId);
						if (meta) {
							this.snapshotInfo[taskId] = meta;
						}
					}
				} else {
					this.prevDecoded.set(slot.id, 0);
					this.startedAt.delete(slot.id_task ?? 0);
				}
			}

			// Fill snapshotInfo for all slots with taskId (including non-processing)
			for (const slot of this.slots) {
				let taskId = slot.id_task;
				if (!taskId || taskId <= 0) {
					taskId = this.lastTaskId.get(slot.id) ?? 0;
				}
				if (taskId && taskId > 0 && !this.snapshotInfo[taskId]) {
					const meta = await SlotsHistoryService.findLatestMeta(taskId);
					if (meta) {
						this.snapshotInfo[taskId] = meta;
					}
				}
			}

			this.historyCount = await SlotsHistoryService.count();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to fetch slots';
		} finally {
			this.loading = false;
		}
	}

	getProtected(taskId: number): boolean | null {
		const info = this.snapshotInfo[taskId];
		return info ? info.protected : null;
	}

	async toggleProtected(taskId: number): Promise<void> {
		const info = this.snapshotInfo[taskId];
		if (!info) return;
		const next = !info.protected;
		await SlotsHistoryService.setProtected(info.id, next);
		this.snapshotInfo[taskId] = { ...info, protected: next };
	}

	private pollTimeoutId: ReturnType<typeof setTimeout> | null = null;

	private schedulePoll(): void {
		this.pollTimeoutId = setTimeout(async () => {
			await this.fetch();
			this.schedulePoll();
		}, 2000);
	}

	startPolling(): void {
		if (this.pollTimeoutId) return;

		this.fetch();
		this.schedulePoll();
	}

	stopPolling(): void {
		if (this.pollTimeoutId) {
			clearTimeout(this.pollTimeoutId);
			this.pollTimeoutId = null;
		}
	}
}

export const slotsStore = new SlotsStore();

export function slots() {
	return slotsStore.slots;
}

export function slotsError() {
	return slotsStore.error;
}

export function slotsLoading() {
	return slotsStore.loading;
}

export function slotsDebugMode() {
	return slotsStore.debugMode;
}

export function slotsHistoryCount() {
	return slotsStore.historyCount;
}

export function slotsAnyProcessing() {
	return slotsStore.anyProcessing;
}

export function slotProtected(taskId: number): boolean | null {
	return slotsStore.getProtected(taskId);
}

export function slotToggleProtected(taskId: number): Promise<void> {
	return slotsStore.toggleProtected(taskId);
}
