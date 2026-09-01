package animate.internal.swf;

import animate.internal.swf.ShapeTypes.Fill;
import animate.internal.swf.ShapeTypes.Shape;
import animate.internal.swf.ShapeTypes.Stroke;
import flixel.math.FlxMath;
import flixel.math.FlxRect;
import format.swf.Data;
import hxGeomAlgo.EarCut;
import flixel.util.FlxColor;

using Lambda;

class ShapeParser
{
  /**
   * Build a new `Shape` instance from raw SWF data
   * @param characterId The character ID of the shape
   * @param data The raw SWF data
   * @return The new `Shape` instance
   */
  public static function parse(characterId:Int, data:ShapeData):Shape
  {
    return switch (data)
    {
      case SHDShape1(bounds, shapes), SHDShape2(bounds, shapes), SHDShape3(bounds, shapes):
        buildShape(characterId, toFlxRect(bounds), shapes);
      case SHDShape4(d):
        buildShape(characterId, toFlxRect(d.shapeBounds), d.shapes);
    }
  }

  static inline function toFlxRect(r:Rect):FlxRect return FlxRect.get(r.left / 20.0, r.top / 20.0, (r.right - r.left) / 20.0, (r.bottom - r.top) / 20.0);

  static function buildShape(characterId:Int, bounds:FlxRect, styleData:ShapeWithStyleData):Shape
  {
    var shape:Shape = new Shape(characterId, bounds);
    for (fs in styleData.fillStyles)
    {
      switch (fs)
      {
        case FSBitmap(cid, mat, _, _):
          shape.bitmapId = cid;
          shape.bitmapMatrix = Document.convertMatrix(mat);
        default:
      }
    }

    var fillStyles:Array<RawFillStyle> = styleData.fillStyles.map(getFillStyle);
    var lineStyles:Array<RawLineStyle> = styleData.lineStyles.map(resolveLineStyle);

    var allFillStyles:Array<RawFillStyle> = fillStyles.copy();
    var allLineStyles:Array<RawLineStyle> = lineStyles.copy();

    var fill0Edges:Map<Int, Array<FlatEdge>> = new Map<Int, Array<FlatEdge>>();
    var fill1Edges:Map<Int, Array<FlatEdge>> = new Map<Int, Array<FlatEdge>>();
    var lineEdges:Map<Int, Array<FlatEdge>> = new Map<Int, Array<FlatEdge>>();

    var x:Int = 0;
    var y:Int = 0;
    var fillStyle0:Int = 0;
    var fillStyle1:Int = 0;
    var lineStyle:Int = 0;
    var fillBase:Int = 0;
    var lineBase:Int = 0;

    inline function addEdge(map:Map<Int, Array<FlatEdge>>, style:Int, x0:Int, y0:Int, x1:Int, y1:Int):Void
    {
      if (style == 0) return;
      var list = map.get(style);
      if (list == null)
      {
        list = [];
        map.set(style, list);
      }
      list.push(new FlatEdge(x0, y0, x1, y1));
    }

    inline function emitStraight(x0:Int, y0:Int, x1:Int, y1:Int):Void
    {
      addEdge(fill1Edges, fillStyle1, x0, y0, x1, y1);
      addEdge(fill0Edges, fillStyle0, x1, y1, x0, y0);
      addEdge(lineEdges, lineStyle, x0, y0, x1, y1);
    }

    inline function flattenQuadratic(x0:Int, y0:Int, cx:Int, cy:Int, x1:Int, y1:Int):Void
    {
      var segs = curveSegmentCount(x0, y0, cx, cy, x1, y1);
      var px = x0;
      var py = y0;
      for (i in 1...segs + 1)
      {
        var t = i / segs;
        var mt = 1 - t;
        var nx = mt * mt * x0 + 2 * mt * t * cx + t * t * x1;
        var ny = mt * mt * y0 + 2 * mt * t * cy + t * t * y1;
        var ix = Math.round(nx);
        var iy = Math.round(ny);
        emitStraight(px, py, ix, iy);
        px = ix;
        py = iy;
      }
    }

    for (rec in styleData.shapeRecords)
    {
      switch (rec)
      {
        case SHREnd:
          break;

        case SHRChange(chg):
          if (chg.moveTo != null)
          {
            x = chg.moveTo.dx;
            y = chg.moveTo.dy;
          }
          if (chg.fillStyle0 != null)
          {
            var raw = chg.fillStyle0.idx;
            fillStyle0 = raw == 0 ? 0 : fillBase + raw;
          }
          if (chg.fillStyle1 != null)
          {
            var raw = chg.fillStyle1.idx;
            fillStyle1 = raw == 0 ? 0 : fillBase + raw;
          }
          if (chg.lineStyle != null)
          {
            var raw = chg.lineStyle.idx;
            lineStyle = raw == 0 ? 0 : lineBase + raw;
          }
          if (chg.newStyles != null)
          {
            fillBase += fillStyles.length;
            lineBase += lineStyles.length;
            fillStyles = chg.newStyles.fillStyles.map(getFillStyle);
            lineStyles = chg.newStyles.lineStyles.map(resolveLineStyle);
            for (fs in fillStyles) allFillStyles.push(fs);
            for (ls in lineStyles) allLineStyles.push(ls);
          }

        case SHREdge(dx, dy):
          var nx = x + dx;
          var ny = y + dy;
          emitStraight(x, y, nx, ny);
          x = nx;
          y = ny;

        case SHRCurvedEdge(cdx, cdy, adx, ady):
          var cx = x + cdx;
          var cy = y + cdy;
          var ax = cx + adx;
          var ay = cy + ady;
          flattenQuadratic(x, y, cx, cy, ax, ay);
          x = ax;
          y = ay;
      }
    }

    var usedStyleIndices:Map<Int, Bool> = new Map<Int, Bool>();
    for (k in fill1Edges.keys()) usedStyleIndices.set(k, true);
    for (k in fill0Edges.keys()) usedStyleIndices.set(k, true);
    var sortedStyleIndices = [for (k in usedStyleIndices.keys()) k];
    sortedStyleIndices.sort((a, b) -> a - b);

    for (styleIndex in sortedStyleIndices)
    {
      var edges:Array<FlatEdge> = [];
      var e1 = fill1Edges.get(styleIndex);
      if (e1 != null) for (e in e1) edges.push(e);
      var e0 = fill0Edges.get(styleIndex);
      if (e0 != null) for (e in e0) edges.push(e);

      if (edges.length == 0) continue;

      var loops:Array<Array<Int>> = connectEdges(edges);
      if (loops.length == 0) continue;

      var style:Null<RawFillStyle> = styleIndex >= 1 && styleIndex <= allFillStyles.length ? allFillStyles[styleIndex - 1] : null;
      var color:Int = style != null ? style.color : 0xFFFF00FF; // Magenta is here as a fallback

      loopsToFill(loops, color, shape.fills);
    }

    var sortedLineIndices:Array<Int> = [for (k in lineEdges.keys()) k];
    sortedLineIndices.sort((a, b) -> a - b);
    for (styleIndex in sortedLineIndices)
    {
      var edges = lineEdges.get(styleIndex);
      if (edges == null || edges.length == 0) continue;
      var style = styleIndex >= 1 && styleIndex <= allLineStyles.length ? allLineStyles[styleIndex - 1] : null;
      if (style == null) continue;
      makeStroke(edges, style, shape.strokes);
    }

    return shape;
  }

  static function getFillStyle(fs:FillStyle):RawFillStyle
  {
    return {
      type: 0,
      color: getFillColor(fs)
    };
  }

  static function getFillColor(fs:FillStyle):Int
  {
    return switch (fs)
    {
      case FSSolid(rgb):
        FlxColor.fromRGB(rgb.r, rgb.g, rgb.b);
      case FSSolidAlpha(rgba):
        FlxColor.fromRGB(rgba.r, rgba.g, rgba.b, rgba.a);

      // TODO: Gradient fill support
      // It just uses the average color for now
      case FSLinearGradient(_, grad):
        gradientAverageColor(grad);
      case FSRadialGradient(_, grad):
        gradientAverageColor(grad);
      case FSFocalGradient(_, fgrad):
        gradientAverageColor(fgrad.data);

      case FSBitmap(_, _, _, _):
        0xFF808080;
    }
  }

  static function gradientAverageColor(grad:Gradient):Int
  {
    if (grad.data.length == 0) return 0xFFFFFFFF;

    var rSum:Int = 0;
    var gSum:Int = 0;
    var bSum:Int = 0;
    var aSum:Int = 0;

    for (gr in grad.data)
    {
      switch (gr)
      {
        case GRRGB(_, col):
          aSum += 255;
          rSum += col.r;
          gSum += col.g;
          bSum += col.b;
        case GRRGBA(_, col):
          aSum += col.a;
          rSum += col.r;
          gSum += col.g;
          bSum += col.b;
      }
    }

    var len:Int = grad.data.length;
    return FlxColor.fromRGB(Std.int(rSum / len), Std.int(gSum / len), Std.int(bSum / len), Std.int(aSum / len));
  }

  static function resolveLineStyle(ls:LineStyle):RawLineStyle
  {
    var color:FlxColor = switch (ls.data)
    {
      case LSRGB(rgb):
        FlxColor.fromRGB(rgb.r, rgb.g, rgb.b);
      case LSRGBA(rgba):
        FlxColor.fromRGB(rgba.r, rgba.g, rgba.b, rgba.a);
      case LS2(d):
        switch (d.fill)
        {
          case null:
            0xFFFFFFFF;
          case LS2FColor(c):
            FlxColor.fromRGB(c.r, c.g, c.b);
          case LS2FStyle(fs):
            getFillColor(fs);
        }
    }

    return {
      widthTwips: ls.width,
      color: color
    };
  }

  static inline function curveSegmentCount(x0:Int, y0:Int, cx:Int, cy:Int, x1:Int, y1:Int):Int
  {
    var chordLen = FlxMath.vectorLength(x1 - x0, y1 - y0);
    var controlDeviation = FlxMath.vectorLength(cx - (x0 + x1) / 2, cy - (y0 + y1) / 2);
    var estimate = Math.sqrt(chordLen + controlDeviation * 2) / 6;
    return Std.int(FlxMath.bound(estimate, 1, 16));
  }

  static function connectEdges(edges:Array<FlatEdge>):Array<Array<Int>>
  {
    inline function skey(x:Int, y:Int):String return x + '_' + y;

    var used = [for (i in 0...edges.length) false];

    var startMap = new Map<String, Array<Int>>();
    for (i in 0...edges.length)
    {
      var e = edges[i];
      var k = skey(e.x0, e.y0);
      var list = startMap.get(k);
      if (list == null)
      {
        list = [];
        startMap.set(k, list);
      }
      list.push(i);
    }

    var loops:Array<Array<Int>> = [];

    for (startIdx in 0...edges.length)
    {
      if (used[startIdx]) continue;

      var loopPoints:Array<Int> = [];
      var currentIdx = startIdx;
      var loopStartKey = skey(edges[startIdx].x0, edges[startIdx].y0);
      var guard = 0;
      var maxSteps = edges.length + 1;

      while (currentIdx != -1 && guard < maxSteps)
      {
        guard++;
        var e = edges[currentIdx];
        used[currentIdx] = true;
        loopPoints.push(e.x0);
        loopPoints.push(e.y0);

        if (skey(e.x1, e.y1) == loopStartKey)
        {
          currentIdx = -1;
          break;
        }

        var candidates = startMap.get(skey(e.x1, e.y1));
        var next = -1;
        if (candidates != null)
        {
          for (c in candidates)
          {
            if (!used[c])
            {
              next = c;
              break;
            }
          }
        }
        currentIdx = next;
      }

      if (loopPoints.length >= 6) loops.push(loopPoints);
    }

    return loops;
  }

  static function loopsToFill(loops:Array<Array<Int>>, color:Int, outFills:Array<Fill>):Void
  {
    function signedArea(loop:Array<Int>):Float
    {
      var sum = 0.0;
      var n = Std.int(loop.length / 2);
      for (i in 0...n)
      {
        var x0 = loop[i * 2];
        var y0 = loop[i * 2 + 1];
        var j = (i + 1) % n;
        var x1 = loop[j * 2];
        var y1 = loop[j * 2 + 1];
        sum += x0 * y1 - x1 * y0;
      }
      return sum * 0.5;
    }

    function bbox(loop:Array<Int>):
      {minX:Int, minY:Int, maxX:Int, maxY:Int}
    {
      var minX = loop[0];
      var maxX = loop[0];
      var minY = loop[1];
      var maxY = loop[1];
      var i = 0;
      while (i < loop.length)
      {
        if (loop[i] < minX) minX = loop[i];
        if (loop[i] > maxX) maxX = loop[i];
        if (loop[i + 1] < minY) minY = loop[i + 1];
        if (loop[i + 1] > maxY) maxY = loop[i + 1];
        i += 2;
      }
      return {
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY
      };
    }

    function pointInLoop(px:Float, py:Float, loop:Array<Int>):Bool
    {
      var inside = false;
      var n = Std.int(loop.length / 2);
      var j = n - 1;
      for (i in 0...n)
      {
        var xi = loop[i * 2];
        var yi = loop[i * 2 + 1];
        var xj = loop[j * 2];
        var yj = loop[j * 2 + 1];
        if (((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi)) inside = !inside;
        j = i;
      }
      return inside;
    }

    var areas = loops.map(signedArea);
    var boxes = loops.map(bbox);
    var positiveArea = 0.0;
    var negativeArea = 0.0;

    for (a in areas)
    {
      if (a >= 0) positiveArea += a;
      else
        negativeArea += -a;
    }

    var outerSignPositive = positiveArea >= negativeArea;

    var outerIndices:Array<Int> = [];
    var holeIndicesAll:Array<Int> = [];
    for (i in 0...loops.length)
    {
      var isOuterWinding = (areas[i] >= 0) == outerSignPositive;
      if (isOuterWinding) outerIndices.push(i);
      else
        holeIndicesAll.push(i);
    }

    var holesForOuter:Array<Array<Int>> = [for (o in outerIndices) []];
    for (hi in holeIndicesAll)
    {
      var hb = boxes[hi];
      var bestOuterPos = -1;
      var bestArea = Math.POSITIVE_INFINITY;
      for (oPos in 0...outerIndices.length)
      {
        var oi = outerIndices[oPos];
        var ob = boxes[oi];
        if (hb.minX >= ob.minX && hb.maxX <= ob.maxX && hb.minY >= ob.minY && hb.maxY <= ob.maxY && pointInLoop(loops[hi][0], loops[hi][1], loops[oi]))
        {
          var a = Math.abs(areas[oi]);
          if (a < bestArea)
          {
            bestArea = a;
            bestOuterPos = oPos;
          }
        }
      }
      if (bestOuterPos != -1) holesForOuter[bestOuterPos].push(hi);
    }

    for (oPos in 0...outerIndices.length)
    {
      var oi = outerIndices[oPos];
      var outerLoop = loops[oi];
      var holes = holesForOuter[oPos];

      var data:Array<Float> = [for (p in outerLoop) p];

      var holeStartIndices:Array<Int> = [];
      for (hi in holes)
      {
        holeStartIndices.push(Std.int(data.length / 2));
        for (p in loops[hi]) data.push(p);
      }

      var triIndices = EarCut.earcut(data, holeStartIndices.length > 0 ? holeStartIndices : null, 2);
      if (triIndices.length == 0) continue;

      outFills.push(new Fill(color, data, triIndices));
    }
  }

  static function makeStroke(edges:Array<FlatEdge>, style:RawLineStyle, outStrokes:Array<Stroke>):Void
  {
    var halfWidth = FlxMath.bound(style.widthTwips, 20.0) / 2;
    var vertices:Array<Float> = [];
    var indices:Array<Int> = [];

    for (e in edges)
    {
      var dx = e.x1 - e.x0;
      var dy = e.y1 - e.y0;
      var len = FlxMath.vectorLength(dx, dy);
      if (len == 0) continue;
      var nx = -dy / len * halfWidth;
      var ny = dx / len * halfWidth;

      var baseIndex = Std.int(vertices.length / 2);
      vertices.push(e.x0 + nx);
      vertices.push(e.y0 + ny);
      vertices.push(e.x0 - nx);
      vertices.push(e.y0 - ny);
      vertices.push(e.x1 - nx);
      vertices.push(e.y1 - ny);
      vertices.push(e.x1 + nx);
      vertices.push(e.y1 + ny);

      indices.push(baseIndex);
      indices.push(baseIndex + 1);
      indices.push(baseIndex + 2);
      indices.push(baseIndex);
      indices.push(baseIndex + 2);
      indices.push(baseIndex + 3);
    }

    if (indices.length > 0) outStrokes.push(new Stroke(style.color, style.widthTwips, vertices, indices));
  }
}

class FlatEdge
{
  public var x0:Int;
  public var y0:Int;
  public var x1:Int;
  public var y1:Int;

  public function new(x0:Int, y0:Int, x1:Int, y1:Int)
  {
    this.x0 = x0;
    this.y0 = y0;
    this.x1 = x1;
    this.y1 = y1;
  }
}

typedef RawFillStyle =
{
  type:Int,
  color:Int
}

typedef RawLineStyle =
{
  widthTwips:Float,
  color:Int
}
