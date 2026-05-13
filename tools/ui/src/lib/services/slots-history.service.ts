import Dexie, { type EntityTable } from 'dexie';

export interface SlotSnapshotMeta {
	id?: number;
	slotId: number;
	taskId: number;
	timestamp: number;
	started_at: number;
	n_decoded: number;
	n_remain: number;
	n_ctx: number;
	speculative: boolean;
	generation_prompt: string;
	temperature: number;
	top_k: number;
	top_p: number;
	repeat_penalty: number;
	samplers: string[];
	debug_mode: boolean;
	protected?: boolean;
}

export interface SlotSnapshot extends SlotSnapshotMeta {
	prompt: string;
	generated: string;
}

function isProtected(s: { protected?: boolean }): boolean {
	return s.protected === true;
}

class SlotsHistoryDatabase extends Dexie {
	snapshots!: EntityTable<SlotSnapshot, number>;
	snapshotMeta!: EntityTable<SlotSnapshotMeta, number>;

	constructor() {
		super('LlamacppSlotsHistory');

		this.version(1).stores({
			snapshots: '++id, taskId, slotId, timestamp'
		});

		this.version(2).stores({
			snapshots: '++id, taskId, slotId, timestamp, protected'
		}).upgrade((tx) => {
			return tx.table('snapshots').toCollection().modify((s) => {
				if (s.protected === undefined) {
					s.protected = false;
				}
			});
		});

		this.version(3).stores({
			snapshots: '++id, taskId, slotId, timestamp, protected',
			snapshotMeta: '++id, taskId, slotId, timestamp, protected'
		}).upgrade(async (tx) => {
			const all = await tx.table('snapshots').toCollection().toArray();
			const metaEntries = all.map((s) => {
				const { prompt, generated, ...meta } = s;
				return { ...meta, protected: meta.protected ?? false };
			});
			if (metaEntries.length > 0) {
				await tx.table('snapshotMeta').bulkAdd(metaEntries);
			}
		});
	}
}

const db = new SlotsHistoryDatabase();

export class SlotsHistoryService {
	static readonly MAX_SNAPSHOTS = 500;

	static async add(snapshot: SlotSnapshot): Promise<void> {
		const { prompt, generated, ...meta } = snapshot;

		const existing = await db.snapshots
			.where('taskId')
			.equals(snapshot.taskId)
			.last();

		if (existing) {
			const started_at = existing.started_at ?? snapshot.timestamp;
			await db.snapshots.update(existing.id!, {
				timestamp: snapshot.timestamp,
				started_at,
				n_decoded: snapshot.n_decoded,
				n_remain: snapshot.n_remain,
				n_ctx: snapshot.n_ctx,
				speculative: snapshot.speculative,
				prompt: snapshot.prompt,
				generated: snapshot.generated,
				generation_prompt: snapshot.generation_prompt,
				temperature: snapshot.temperature,
				top_k: snapshot.top_k,
				top_p: snapshot.top_p,
				repeat_penalty: snapshot.repeat_penalty,
				samplers: snapshot.samplers,
				debug_mode: snapshot.debug_mode
			});
			await db.snapshotMeta.where('taskId').equals(snapshot.taskId).modify({
				timestamp: snapshot.timestamp,
				started_at,
				n_decoded: snapshot.n_decoded,
				n_remain: snapshot.n_remain,
				n_ctx: snapshot.n_ctx,
				speculative: snapshot.speculative,
				generation_prompt: snapshot.generation_prompt,
				temperature: snapshot.temperature,
				top_k: snapshot.top_k,
				top_p: snapshot.top_p,
				repeat_penalty: snapshot.repeat_penalty,
				samplers: snapshot.samplers,
				debug_mode: snapshot.debug_mode
			});
			return;
		}

		// New task: add with eviction
		const count = await db.snapshotMeta.count();

		if (count >= this.MAX_SNAPSHOTS) {
			const allEntries = await db.snapshotMeta.orderBy('id').toArray();
			const toEvictCount = count - this.MAX_SNAPSHOTS + 1;

			allEntries.sort((a, b) => {
				const aUnprotected = !isProtected(a);
				const bUnprotected = !isProtected(b);
				if (aUnprotected !== bUnprotected) return aUnprotected ? -1 : 1;
				return a.id! - b.id!;
			});

			const toDelete = allEntries.slice(0, toEvictCount).map((s) => s.id!);
			await db.snapshots.bulkDelete(toDelete);
			await db.snapshotMeta.bulkDelete(toDelete);
		}

		const id = await db.snapshots.add(snapshot);
		await db.snapshotMeta.add({ ...meta, id, protected: false });
	}

	static async setProtected(id: number, value: boolean): Promise<void> {
		await db.snapshots.update(id, { protected: value });
		await db.snapshotMeta.update(id, { protected: value });
	}

	static async findLatestMeta(taskId: number): Promise<{ id: number; protected: boolean } | null> {
		const entry = await db.snapshotMeta
			.where('taskId')
			.equals(taskId)
			.last();
		if (!entry || !entry.id) return null;
		return { id: entry.id, protected: entry.protected === true };
	}

	static async list(): Promise<SlotSnapshotMeta[]> {
		return db.snapshotMeta.orderBy('timestamp').reverse().toArray();
	}

	static async getDetail(id: number): Promise<SlotSnapshot | undefined> {
		return db.snapshots.get(id);
	}

	static async count(): Promise<number> {
		return db.snapshotMeta.count();
	}

	static async clear(): Promise<void> {
		await db.snapshots.clear();
		await db.snapshotMeta.clear();
	}

	static async deleteDatabase(): Promise<void> {
		await db.delete();
	}

	static async estimateStorage(): Promise<string> {
		const count = await db.snapshots.count();
		if (count === 0) return '0 B';

		const sample = await db.snapshots.orderBy('id').reverse().limit(5).toArray();
		if (sample.length === 0) return '0 B';

		let totalBytes = 0;
		for (const entry of sample) {
			const json = JSON.stringify(entry);
			totalBytes += new TextEncoder().encode(json).length;
		}

		const avgBytes = totalBytes / sample.length;
		const estimatedBytes = avgBytes * count;

		if (estimatedBytes < 1024) return `${Math.round(estimatedBytes)} B`;
		if (estimatedBytes < 1024 * 1024) return `${(estimatedBytes / 1024).toFixed(1)} KB`;
		return `${(estimatedBytes / (1024 * 1024)).toFixed(1)} MB`;
	}

	static async estimateItemSize(id: number): Promise<string> {
		const entry = await db.snapshots.get(id);
		if (!entry) return '';
		const bytes = new TextEncoder().encode(JSON.stringify(entry)).length;
		if (bytes < 1024) return `${bytes} B`;
		if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
		return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
	}
}
