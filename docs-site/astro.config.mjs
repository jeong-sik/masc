// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mermaid from 'astro-mermaid';

// https://astro.build/config
export default defineConfig({
	integrations: [
		// autoTheme followed the visitor's OS, but custom.css pins the page dark
		// for every value of data-theme. A light OS therefore drew a light diagram
		// on a black page. One theme, like the rest of the chrome.
		mermaid({
			theme: 'dark',
			autoTheme: false,
		}),
		starlight({
			// Same reason as the diagrams: the page is dark at every data-theme, so
			// a code block that follows the OS came out white on black.
			expressiveCode: { themes: ['github-dark'] },
			title: 'MASC',
			description: 'Multi-Agent Shared Context & Autonomous Coding Agent Harness',
			defaultLocale: 'root',
			customCss: ['./src/styles/custom.css'],
			locales: {
				root: {
					label: 'English',
					lang: 'en',
				},
				ko: {
					label: '한국어',
					lang: 'ko',
				},
			},
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/jeong-sik/masc' }
			],
			components: {
				Head: './src/components/CustomHead.astro',
			},
			sidebar: [
				{
					label: 'Getting Started',
					translations: { 'ko': '시작하기' },
					items: [
						{ label: 'Overview', translations: { 'ko': 'MASC 개요' }, slug: 'getting-started/overview' },
						{ label: 'Quickstart', translations: { 'ko': '빠른 시작' }, slug: 'getting-started/quickstart' },
						{ label: 'Build from Source', translations: { 'ko': '소스에서 빌드하기' }, slug: 'getting-started/install-from-source' },
						{ label: 'FAQ', translations: { 'ko': '자주 묻는 질문 (FAQ)' }, slug: 'getting-started/faq' },
					],
				},
				{
					label: 'User Guides',
					translations: { 'ko': '사용 가이드' },
					items: [
						{ label: 'Terminal UI (TUI)', translations: { 'ko': '터미널에서 조작하기' }, slug: 'guides/tui' },
						{ label: 'Running Keepers', translations: { 'ko': 'Keeper 사용하기' }, slug: 'guides/keeper' },
						{ label: 'Connecting MCP clients', translations: { 'ko': 'MCP 클라이언트 연결' }, slug: 'guides/mcp-clients' },
					],
				},
				{
					label: 'Operations',
					translations: { 'ko': '운영 가이드' },
					items: [
						{ label: 'Local Models', translations: { 'ko': '로컬 AI 모델 연결' }, slug: 'runbooks/llama-server' },
						{ label: 'Docker Sandbox', translations: { 'ko': '명령어 안전 격리' }, slug: 'runbooks/sandbox' },
						{ label: 'Troubleshooting', translations: { 'ko': '문제 해결' }, slug: 'runbooks/troubleshooting' },
					],
				},
				{
					label: 'Configuration',
					translations: { 'ko': '설정 안내' },
					items: [
						{ label: 'Environment Variables', translations: { 'ko': '환경 변수' }, slug: 'reference/env-contract' },
						{ label: 'Config Files (.toml)', translations: { 'ko': '설정 파일' }, slug: 'reference/config' },
					],
				},
				{
					label: 'How MASC Works',
					translations: { 'ko': '핵심 동작 원리' },
					items: [
						{ label: 'Core Principles', translations: { 'ko': '핵심 동작 원칙' }, slug: 'architecture/constitution' },
						{ label: 'Long-Term Memory', translations: { 'ko': '세션을 넘나드는 장기 기억' }, slug: 'architecture/memory-os' },
					],
				},
				{
					label: 'Design Decisions',
					translations: { 'ko': '설계 의사결정' },
					items: [
						{ label: 'Multi-Model Deliberation', translations: { 'ko': '다중 모델 심의 (Fusion)' }, slug: 'architecture/fusion' },
						{ label: 'Design History', translations: { 'ko': '설계 배경과 발전 과정' }, slug: 'architecture/rfc-index' },
					],
				},
			],
		}),
	],
});
