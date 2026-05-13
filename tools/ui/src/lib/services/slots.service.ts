import { apiFetch } from '$lib/utils';
import { API_SLOTS } from '$lib/constants/api-endpoints';

export class SlotsService {
	static async list(): Promise<ApiSlotData[]> {
		return apiFetch<ApiSlotData[]>(API_SLOTS.LIST);
	}
}
