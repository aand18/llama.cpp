export function stripSpecialTokens(text: string): string {
	if (!text) return '';

	return text
		.replace(/<\|im_start\|>/g, '\n[im_start] ')
		.replace(/<\|im_end\|>/g, '\n[im_end]')
		.replace(/<\|begin_of_text\|>/g, '[BOT] ')
		.replace(/<\|eot_id\|>/g, ' [EOT]')
		.replace(/<\|eom_id\|>/g, ' [EOM]')
		.replace(/<\|start_header_id\|>/g, '[header] ')
		.replace(/<\|end_header_id\|>/g, ' [end_header]')
		.replace(/<\|reserved_special_token_\d+\/>/g, '')
		.replace(/<\/?(?:function)[^>]*>/g, '')
		.replace(/<\|[^>]*\|?>/g, '')
		.replace(/\n{3,}/g, '\n\n')
		.trim();
}

export function stripToolTags(text: string): string {
	if (!text) return '';

	return text
		.replace(/<tool_call>\s*\n?/g, '')
		.replace(/<\/tool_call>\s*\n?/g, '')
		.replace(/<tool_response>\s*\n?/g, '')
		.replace(/<\/tool_response>\s*\n?/g, '')
		.replace(/<function=[^>]*>\s*\n?/g, '')
		.replace(/<\/function>\s*\n?/g, '')
		.replace(/\n{3,}/g, '\n\n')
		.trim();
}

export function prettyText(text: string): string {
	return stripToolTags(stripSpecialTokens(text));
}

export function escapeHtml(text: string): string {
	if (!text) return '';

	return text
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#039;');
}
