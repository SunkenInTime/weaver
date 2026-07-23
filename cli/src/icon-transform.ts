import ts from "typescript";
import {
  DEFAULT_ICON_VIEW_BOX,
  isIconName,
  normalizedLucidePath,
  normalizeSvgPath,
  normalizeViewBox,
  unknownIconMessage,
} from "./icon-paths.js";

export interface LoweredIconSpec {
  path: string;
  viewBox: string;
  stroke: number;
}

function attribute(sourceFile: ts.SourceFile, attributes: ts.JsxAttributes, name: string): ts.JsxAttribute | undefined {
  return attributes.properties.find((property): property is ts.JsxAttribute =>
    ts.isJsxAttribute(property) && property.name.getText(sourceFile) === name);
}

function stringValue(initializer: ts.JsxAttributeValue | undefined): string | null {
  if (!initializer) return null;
  if (ts.isStringLiteral(initializer)) return initializer.text;
  if (ts.isJsxExpression(initializer) && initializer.expression &&
      (ts.isStringLiteral(initializer.expression) || ts.isNoSubstitutionTemplateLiteral(initializer.expression))) {
    return initializer.expression.text;
  }
  return null;
}

function numberValue(initializer: ts.JsxAttributeValue | undefined): number | null {
  if (!initializer || !ts.isJsxExpression(initializer) || !initializer.expression) return null;
  const expression = initializer.expression;
  if (ts.isNumericLiteral(expression)) return Number(expression.text);
  if (ts.isPrefixUnaryExpression(expression) && expression.operator === ts.SyntaxKind.MinusToken && ts.isNumericLiteral(expression.operand)) {
    return -Number(expression.operand.text);
  }
  return null;
}

export function resolveIconSpec(sourceFile: ts.SourceFile, attributes: ts.JsxAttributes): LoweredIconSpec {
  const nameAttribute = attribute(sourceFile, attributes, "name");
  const pathAttribute = attribute(sourceFile, attributes, "d");
  const viewBoxAttribute = attribute(sourceFile, attributes, "viewBox");
  const strokeAttribute = attribute(sourceFile, attributes, "stroke");
  for (const internal of ["iconPath", "iconViewBox", "iconStroke"]) {
    if (attribute(sourceFile, attributes, internal)) throw new Error(`<icon> ${internal} is bundle-internal and cannot be authored`);
  }
  if (Boolean(nameAttribute) === Boolean(pathAttribute)) {
    throw new Error("<icon> requires exactly one of name or d");
  }
  if (nameAttribute) {
    if (viewBoxAttribute || strokeAttribute) throw new Error("<icon name> uses Lucide's 24-viewBox and 2px stroke; viewBox/stroke are only valid with d");
    const name = stringValue(nameAttribute.initializer);
    if (name === null || name.length === 0) throw new Error("<icon> name must be a literal Lucide name");
    if (!isIconName(name)) throw new Error(unknownIconMessage(name));
    return { path: normalizedLucidePath(name), viewBox: DEFAULT_ICON_VIEW_BOX, stroke: 2 };
  }
  const rawPath = stringValue(pathAttribute!.initializer);
  if (rawPath === null || rawPath.length === 0) throw new Error("<icon> d must be literal SVG path data");
  const rawViewBox = viewBoxAttribute ? stringValue(viewBoxAttribute.initializer) : DEFAULT_ICON_VIEW_BOX;
  if (rawViewBox === null) throw new Error("<icon> viewBox must be a literal string");
  let stroke = 0;
  if (strokeAttribute) {
    const value = numberValue(strokeAttribute.initializer);
    if (value === null || !Number.isFinite(value) || value <= 0 || value > 1000) {
      throw new Error("<icon> stroke must be a positive finite numeric literal no larger than 1000");
    }
    stroke = value;
  }
  return {
    path: normalizeSvgPath(rawPath),
    viewBox: normalizeViewBox(rawViewBox),
    stroke,
  };
}

function loweredAttributes(sourceFile: ts.SourceFile, attributes: ts.JsxAttributes, spec: LoweredIconSpec): ts.JsxAttributes {
  const retained = attributes.properties.filter((property) => {
    if (!ts.isJsxAttribute(property)) return true;
    return !["name", "d", "viewBox", "stroke"].includes(property.name.getText(sourceFile));
  });
  return ts.factory.createJsxAttributes([
    ...retained,
    ts.factory.createJsxAttribute(ts.factory.createIdentifier("iconPath"), ts.factory.createStringLiteral(spec.path)),
    ts.factory.createJsxAttribute(ts.factory.createIdentifier("iconViewBox"), ts.factory.createStringLiteral(spec.viewBox)),
    ts.factory.createJsxAttribute(
      ts.factory.createIdentifier("iconStroke"),
      ts.factory.createJsxExpression(undefined, ts.factory.createNumericLiteral(spec.stroke)),
    ),
  ]);
}

function sourceContainsIcon(sourceFile: ts.SourceFile): boolean {
  let found = false;
  const visit = (node: ts.Node): void => {
    if ((ts.isJsxSelfClosingElement(node) || ts.isJsxOpeningElement(node)) &&
        node.tagName.getText(sourceFile) === "icon") {
      found = true;
      return;
    }
    if (!found) ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return found;
}

export function lowerIconSource(sourcePath: string, source: string): string {
  const sourceFile = ts.createSourceFile(sourcePath, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  if (!sourceContainsIcon(sourceFile)) return source;
  const transformer: ts.TransformerFactory<ts.SourceFile> = (context) => {
    const visit: ts.Visitor = (node) => {
      if (ts.isJsxSelfClosingElement(node) && node.tagName.getText(sourceFile) === "icon") {
        const spec = resolveIconSpec(sourceFile, node.attributes);
        return ts.factory.updateJsxSelfClosingElement(node, node.tagName, node.typeArguments, loweredAttributes(sourceFile, node.attributes, spec));
      }
      if (ts.isJsxOpeningElement(node) && node.tagName.getText(sourceFile) === "icon") {
        const spec = resolveIconSpec(sourceFile, node.attributes);
        return ts.factory.updateJsxOpeningElement(node, node.tagName, node.typeArguments, loweredAttributes(sourceFile, node.attributes, spec));
      }
      return ts.visitEachChild(node, visit, context);
    };
    return (root) => ts.visitNode(root, visit) as ts.SourceFile;
  };
  const transformed = ts.transform(sourceFile, [transformer]);
  try {
    return ts.createPrinter().printFile(transformed.transformed[0]);
  } finally {
    transformed.dispose();
  }
}
