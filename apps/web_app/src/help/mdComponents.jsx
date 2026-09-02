import React, { useState, Children } from 'react';

// Якорь заголовка: тот же алгоритм используется при построении оглавления,
// иначе ссылки в содержании ведут в пустоту.
export function slugify(text) {
  return String(text)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '');
}

function childrenText(children) {
  return Children.toArray(children)
    .map(c => (typeof c === 'string' ? c : c?.props?.children ? childrenText(c.props.children) : ''))
    .join('');
}

// Скриншоты доклеиваются позже: пока файла в public/help/img нет, на его месте
// стоит рамка с именем файла и подписью — текст можно писать, не дожидаясь фото.
function HelpImage({ src, alt }) {
  const [failed, setFailed] = useState(false);
  if (failed || !src) {
    return (
      <figure className="my-5">
        <div className="border-2 border-dashed border-slate-300 rounded-2xl bg-slate-50 px-4 py-10 text-center">
          <div className="text-[11px] font-black uppercase tracking-wide text-slate-400">
            скриншот появится здесь
          </div>
          <div className="mt-2 text-sm font-bold text-slate-600">{alt}</div>
          <div className="mt-1 text-[11px] font-mono text-slate-400 break-all">{src}</div>
        </div>
      </figure>
    );
  }
  return (
    <figure className="my-5">
      <img
        src={src}
        alt={alt}
        loading="lazy"
        onError={() => setFailed(true)}
        className="w-full rounded-2xl border border-slate-200 shadow-sm"
      />
      {alt && <figcaption className="mt-2 text-xs text-slate-500 text-center">{alt}</figcaption>}
    </figure>
  );
}

function isImageOnly(children) {
  const kids = Children.toArray(children).filter(c => typeof c !== 'string' || c.trim() !== '');
  return kids.length === 1 && kids[0]?.type === HelpImage;
}

export function makeComponents(chapterId) {
  const anchor = children => `${chapterId}--${slugify(childrenText(children))}`;

  return {
    h1: ({ children }) => (
      <h1 className="text-2xl sm:text-3xl font-black text-primary mb-4 font-lexend">{children}</h1>
    ),
    h2: ({ children }) => (
      <h2
        id={anchor(children)}
        className="help-h2 text-xl sm:text-2xl font-black text-primary mt-10 mb-3 scroll-mt-24 font-lexend"
      >
        {children}
      </h2>
    ),
    h3: ({ children }) => (
      <h3 id={anchor(children)} className="text-base font-black text-slate-800 mt-6 mb-2 scroll-mt-24">
        {children}
      </h3>
    ),
    p: ({ children }) =>
      isImageOnly(children) ? <>{children}</> : <p className="my-3 leading-7 text-slate-700">{children}</p>,
    ul: ({ children }) => <ul className="my-3 pl-5 list-disc space-y-1.5 text-slate-700">{children}</ul>,
    ol: ({ children }) => <ol className="my-3 pl-5 list-decimal space-y-1.5 text-slate-700">{children}</ol>,
    li: ({ children }) => <li className="leading-7">{children}</li>,
    strong: ({ children }) => <strong className="font-black text-slate-900">{children}</strong>,
    a: ({ href, children }) => (
      <a href={href} className="text-primary font-bold underline underline-offset-2 break-words">
        {children}
      </a>
    ),
    // Цитата используется как «обратите внимание».
    blockquote: ({ children }) => (
      <blockquote className="help-note my-4 rounded-2xl border-l-4 border-tertiary-container bg-amber-50/70 px-4 py-3 text-slate-700 [&>p]:my-1">
        {children}
      </blockquote>
    ),
    // react-markdown больше не передаёт `inline`: оформляем code как строчный,
    // а внутри <pre> подложку и отступы снимаем классами родителя.
    code: ({ children, className }) => (
      <code
        className={`rounded-md bg-slate-100 px-1.5 py-0.5 text-[0.85em] font-mono text-slate-800 ${className || ''}`}
      >
        {children}
      </code>
    ),
    pre: ({ children }) => (
      <pre className="help-pre my-4 overflow-x-auto rounded-2xl bg-slate-900 p-4 text-slate-100 text-[0.85em] leading-6 [&_code]:bg-transparent [&_code]:p-0 [&_code]:text-inherit">
        {children}
      </pre>
    ),
    table: ({ children }) => (
      <div className="help-table my-4 overflow-x-auto rounded-2xl border border-slate-200">
        <table className="w-full text-sm border-collapse">{children}</table>
      </div>
    ),
    thead: ({ children }) => <thead className="bg-slate-50">{children}</thead>,
    th: ({ children }) => (
      <th className="border-b border-slate-200 px-3 py-2 text-left text-xs font-black uppercase tracking-wide text-slate-500">
        {children}
      </th>
    ),
    td: ({ children }) => (
      <td className="border-b border-slate-100 px-3 py-2 align-top text-slate-700">{children}</td>
    ),
    hr: () => <hr className="my-8 border-slate-200" />,
    img: HelpImage,
  };
}
