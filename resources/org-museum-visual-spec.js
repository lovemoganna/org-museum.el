/**
 * Org Museum Visual Specification & Formatter Layer (v1.0)
 * 统一可视化公共层：涵盖 Formatter（格式化层）、Chart Spec（分析与配置层）及渲染避让规则。
 * 遵循 MECE 原则，收敛所有图表组件的计算、单位、格式化、Tooltip 和 Label 避让。
 */
(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.OrgMuseumVisual = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ==========================================
  // 1. 统一格式化层 (Formatter)
  // ==========================================
  var Formatter = {
    /**
     * 基础数值格式化
     * @param {number|string} val - 原始数值
     * @param {Object} [opts] - 选项
     * @param {number} [opts.decimals] - 小数位数
     * @param {boolean} [opts.useGrouping=true] - 是否使用千分位
     * @param {boolean} [opts.short=false] - 是否启用 K/M/B 大数缩写 (如 12.4K, 1.2M)
     * @param {string} [opts.fallback='0'] - 空值或异常值回退
     * @returns {string} 格式化后的字符串
     */
    formatNumber: function (val, opts) {
      opts = opts || {};
      var fallback = opts.fallback != null ? opts.fallback : '0';
      if (val == null || val === '') return fallback;
      var num = Number(val);
      if (!Number.isFinite(num)) return fallback;

      var useGrouping = opts.useGrouping !== false;
      var decimals = opts.decimals;

      if (opts.short && Math.abs(num) >= 1000) {
        var abs = Math.abs(num);
        var sign = num < 0 ? '-' : '';
        if (abs >= 1e9) {
          return sign + (abs / 1e9).toFixed(decimals != null ? decimals : 1).replace(/\.0$/, '') + 'B';
        }
        if (abs >= 1e6) {
          return sign + (abs / 1e6).toFixed(decimals != null ? decimals : 1).replace(/\.0$/, '') + 'M';
        }
        if (abs >= 1e3) {
          return sign + (abs / 1e3).toFixed(decimals != null ? decimals : 1).replace(/\.0$/, '') + 'K';
        }
      }

      var parts = (decimals != null ? num.toFixed(decimals) : String(num)).split('.');
      if (useGrouping) {
        parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
      }
      return parts.join('.');
    },

    /**
     * 百分比格式化
     * @param {number} val - 分子
     * @param {number} total - 分母
     * @param {number} [decimals=1] - 小数位
     * @returns {string} 如 "23.6%"
     */
    formatPercent: function (val, total, decimals) {
      if (decimals == null) decimals = 1;
      var v = Number(val), t = Number(total);
      if (!Number.isFinite(v) || !Number.isFinite(t) || t <= 0) {
        return '0.0%'.slice(0, 3 + (decimals > 0 ? decimals + 1 : 0));
      }
      var p = (v / t) * 100;
      return p.toFixed(decimals) + '%';
    },

    /**
     * 带单位的数值格式化
     * @param {number|string} val
     * @param {string} unit - 计量单位 (如 "篇", "%", "¥")
     * @param {Object} [opts]
     */
    formatValueWithUnit: function (val, unit, opts) {
      var numStr = Formatter.formatNumber(val, opts);
      if (!unit) return numStr;
      if (unit === '¥' || unit === '$') return unit + numStr;
      if (unit === '%') return numStr + '%';
      return numStr + ' ' + unit;
    },

    /**
     * 坐标轴刻度格式化
     */
    formatAxisTick: function (val) {
      return Formatter.formatNumber(val, { short: true, decimals: 1 });
    },

    /**
     * 时间与日期区间格式化
     */
    formatDateRange: function (start, end) {
      if (!start && !end) return '全部时间';
      if (start && end) {
        return start === end ? start : start + ' ~ ' + end;
      }
      if (start) return start + ' 至今';
      return '截止 ' + end;
    }
  };

  // ==========================================
  // 2. 统一 Chart Spec (规范与分析层)
  // ==========================================
  var ChartSpec = {
    /**
     * 计算坐标轴最佳阶梯刻度 (自动对齐零轴与整型刻度)
     * @param {number} max - 最大值
     * @param {number} [min=0] - 最小值
     * @returns {{ ceiling: number, ticks: number[] }}
     */
    computeAxisScale: function (max, min) {
      if (min == null) min = 0;
      if (max == null || max <= 0) {
        return {
          ceiling: 1,
          ticks: [1, min]
        };
      }
      var ceiling;
      if (max <= 3) ceiling = 3;
      else if (max <= 6) ceiling = 6;
      else if (max <= 10) ceiling = 10;
      else if (max <= 25) ceiling = Math.ceil(max / 5) * 5;
      else if (max <= 100) ceiling = Math.ceil(max / 10) * 10;
      else ceiling = Math.ceil(max / 50) * 50;

      var mid = Math.round(ceiling / 2);
      return {
        ceiling: ceiling,
        ticks: [ceiling, mid, min]
      };
    },

    /**
     * 柱状图 / 条形图 Label 智能外置与防遮挡避让算法
     * 满足规范：Label 超出空间时自动外置，禁止遮挡或截断；避免相邻重叠。
     * @param {Object} params
     * @param {number} params.barHeight - 柱体当前高度 (px 或百分比数字 0-100)
     * @param {number} params.containerHeight - 容器总高度 (px)
     * @param {number} params.columnWidth - 柱体宽度 (px)
     * @param {number} params.value - 当前数值
     * @returns {{ placement: 'inside'|'outside'|'top-submerged'|'hidden', isOutside: boolean }}
     */
    computeLabelLayout: function (params) {
      var barHeight = Number(params.barHeight) || 0;
      var containerHeight = Number(params.containerHeight) || 110;
      var columnWidth = Number(params.columnWidth) || 20;
      var value = Number(params.value) || 0;

      if (value === 0) {
        return { placement: 'hidden', isOutside: false };
      }

      // 如果是百分比表示的高度 (0-100)
      var heightPx = barHeight <= 1 ? barHeight * containerHeight : (barHeight <= 100 ? (barHeight / 100) * containerHeight : barHeight);

      // 规则1：柱体高度不足 (< 28px) 时自动外置于柱顶之上，禁止内部强行挤压
      if (heightPx < 28) {
        return { placement: 'outside', isOutside: true };
      }

      // 规则2：柱体过高 (距离容器顶部 < 18px)，如果继续外置会冲出上边界越界，因此下沉至柱体内部顶部展示
      if (containerHeight - heightPx < 22) {
        return { placement: 'top-submerged', isOutside: false };
      }

      // 规则3：正常柱体空间充裕，置于柱顶外部清晰展示
      return { placement: 'outside', isOutside: true };
    },

    /**
     * 统一 Tooltip 结构构建器
     * 满足规范：Hover 显示 维度 + 数值 + 单位 + 时间/占比
     * @param {Object} params
     * @param {string} params.title - 标题/日期/维度名
     * @param {Array<{label: string, value: number, unit?: string, percent?: string, color?: string}>} params.items
     * @returns {string} 统一格式化后的富文本或文本
     */
    buildTooltipText: function (params) {
      var lines = [];
      if (params.title) lines.push(params.title);
      (params.items || []).forEach(function (item) {
        var line = (item.label ? item.label + '：' : '') + Formatter.formatValueWithUnit(item.value, item.unit || '篇');
        if (item.percent) line += ' (' + item.percent + ')';
        lines.push(line);
      });
      return lines.join(' · ');
    },

    /**
     * 创建标准化通用 Chart Spec
     */
    createSpec: function (spec) {
      return Object.assign({
        type: 'custom',
        title: '',
        unit: '篇',
        data: [],
        dimensions: [],
        measures: [],
        emptyText: '当前条件下无数据',
        legendPosition: 'bottom'
      }, spec);
    }
  };

  return {
    version: '1.0.0',
    Formatter: Formatter,
    ChartSpec: ChartSpec
  };
});
